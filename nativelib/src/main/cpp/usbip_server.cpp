/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * usbip_server.cpp - USB/IP server over the HarmonyOS USB DDK.
 *
 * USB/IP 1.1.1 wire protocol constants and framing are ported from the
 * Linux kernel usbip protocol (Documentation/usb/usbip_protocol.rst) and
 * cross-checked against Sunshine's loopback_usbip_bridge.
 */

#include "usbip_server.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

#include <dlfcn.h>
#include <hilog/log.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <arpa/inet.h>

#define LOG_TAG "UsbIpServer"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace usbip {

// ============================================================
// USB/IP wire constants (all big-endian on the wire)
// ============================================================

namespace wire {

constexpr uint16_t kVersion = 0x0111;
constexpr uint16_t kOpReqDevlist = 0x8005;
constexpr uint16_t kOpRepDevlist = 0x0005;
constexpr uint16_t kOpReqImport = 0x8003;
constexpr uint16_t kOpRepImport = 0x0003;
constexpr int kOpCommonSize = 8;            // version + code + status
constexpr int kUsbDeviceStructSize = 0x138; // 312 bytes
constexpr int kPduHeaderSize = 48;
constexpr int kBusIdSize = 32;

constexpr uint32_t kCmdSubmit = 0x00000001;
constexpr uint32_t kCmdUnlink = 0x00000002;
constexpr uint32_t kRetSubmit = 0x00000003;
constexpr uint32_t kRetUnlink = 0x00000004;

constexpr int32_t kUsbErrIo = -5;        // -EIO
constexpr int32_t kUsbErrNoent = -2;     // -ENOENT
constexpr int32_t kUsbErrConnreset = -104; // -ECONNRESET (URB canceled before completion)
constexpr int32_t kUsbErrOverflow = -75; // -EOVERFLOW
constexpr int32_t kUsbErrTimedout = -110;// -ETIMEDOUT

// DDK error codes (usb_ddk_types.h)
constexpr int32_t kDdkTimeout = 27400004;

// 312-byte usbip_usb_device layout offsets
constexpr int kBusidOffset = 0x100;      // busid[32]
constexpr int kBusnumOffset = 0x120;
constexpr int kDevnumOffset = 0x124;
constexpr int kSpeedOffset = 0x128;
constexpr int kIdVendorOffset = 0x12C;
constexpr int kIdProductOffset = 0x12E;
constexpr int kBcdDeviceOffset = 0x130;
constexpr int kClassOffset = 0x132;
constexpr int kSubclassOffset = 0x133;
constexpr int kProtocolOffset = 0x134;
constexpr int kConfigValueOffset = 0x135;
constexpr int kNumConfigsOffset = 0x136;
constexpr int kNumInterfacesOffset = 0x137;

// 48-byte PDU header offsets. The payload is a union per direction:
// [20] transfer_flags / status / unlink target, [24] transfer_buffer_length
// / actual_length, [36] interval / error_count.
constexpr int kCmdOffset = 0;
constexpr int kSeqnumOffset = 4;
constexpr int kDirectionOffset = 12;
constexpr int kEpOffset = 16;
constexpr int kFlagsOrUnlinkTargetOffset = 20;
constexpr int kLenOrActualOffset = 24;
constexpr int kStartFrameOffset = 28;
constexpr int kNumPacketsOrErrorOffset = 32;
constexpr int kIntervalOffset = 36;
constexpr int kErrorCountOffset = 36;
constexpr int kSetupOffset = 40;         // setup[8]

void appendU16(std::vector<uint8_t> &out, uint16_t v) {
    out.push_back((v >> 8) & 0xFF);
    out.push_back(v & 0xFF);
}
void appendU32(std::vector<uint8_t> &out, uint32_t v) {
    out.push_back((v >> 24) & 0xFF);
    out.push_back((v >> 16) & 0xFF);
    out.push_back((v >> 8) & 0xFF);
    out.push_back(v & 0xFF);
}

uint16_t readU16(const uint8_t *p) {
    return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}
// USB/IP headers use network byte order, but setup[8] contains the original
// USB setup packet. Its three 16-bit fields retain USB little-endian order.
uint16_t readUsbU16(const uint8_t *p) {
    return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}
uint32_t readU32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
int32_t readI32(const uint8_t *p) {
    return static_cast<int32_t>(readU32(p));
}

// Big-endian store at a fixed offset. PDU reply headers are pre-sized
// buffers; appendU32 would push fields past the end of the header.
void storeU32(uint8_t *p, int off, uint32_t v) {
    p[off] = (v >> 24) & 0xFF;
    p[off + 1] = (v >> 16) & 0xFF;
    p[off + 2] = (v >> 8) & 0xFF;
    p[off + 3] = v & 0xFF;
}
void storeI32(uint8_t *p, int off, int32_t v) {
    storeU32(p, off, static_cast<uint32_t>(v));
}

bool writeAll(int fd, const uint8_t *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        const ssize_t n = ::write(fd, data + off, len - off);
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

bool writeVec(int fd, const std::vector<uint8_t> &v) {
    return writeAll(fd, v.data(), v.size());
}

// Blocking exact read. Only call after poll() reported readability (the
// tunnel peer never trickles, so this cannot wedge).
bool readAll(int fd, uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        const ssize_t n = ::read(fd, buf + off, len - off);
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

// True when the socket has data within timeoutMs (0 = non-blocking probe).
bool waitReadable(int fd, int timeoutMs) {
    pollfd pfd{fd, POLLIN, 0};
    return ::poll(&pfd, 1, timeoutMs) > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR));
}

// The 312-byte usbip_usb_device struct for a registered device.
std::vector<uint8_t> buildDeviceEntry(const DeviceInfo &dev) {
    std::vector<uint8_t> entry(kUsbDeviceStructSize, 0);
    const std::string busid = dev.busId.substr(0, kBusIdSize - 1);
    std::memcpy(entry.data() + kBusidOffset, busid.c_str(), busid.size());
    const auto putU16 = [&](int off, uint16_t v) {
        entry[off] = (v >> 8) & 0xFF;
        entry[off + 1] = v & 0xFF;
    };
    const auto putU32 = [&](int off, uint32_t v) {
        entry[off] = (v >> 24) & 0xFF;
        entry[off + 1] = (v >> 16) & 0xFF;
        entry[off + 2] = (v >> 8) & 0xFF;
        entry[off + 3] = v & 0xFF;
    };
    putU32(kBusnumOffset, dev.busNum);
    putU32(kDevnumOffset, dev.devAddress);
    putU32(kSpeedOffset, dev.speed);
    putU16(kIdVendorOffset, dev.vendorId);
    putU16(kIdProductOffset, dev.productId);
    putU16(kBcdDeviceOffset, dev.bcdDevice);
    entry[kClassOffset] = dev.klass;
    entry[kSubclassOffset] = dev.subclass;
    entry[kProtocolOffset] = dev.protocol;
    entry[kConfigValueOffset] = 1;
    entry[kNumConfigsOffset] = dev.numConfigurations;
    entry[kNumInterfacesOffset] = static_cast<uint8_t>(dev.interfaces.size());
    return entry;
}

} // namespace wire

// ============================================================
// DDK loader
// ============================================================

std::shared_ptr<DdkApi> LoadDdk() {
    auto api = std::make_shared<DdkApi>();
    api->handle = dlopen("libusb_ndk.z.so", RTLD_LAZY);
    if (api->handle == nullptr) {
        LOGE("[%{public}s] dlopen libusb_ndk.z.so failed: %{public}s", LOG_TAG, dlerror());
        return nullptr;
    }
    auto load = [&](const char *name) -> void * {
        return dlsym(api->handle, name);
    };
    api->Init = reinterpret_cast<int32_t (*)(void)>(load("OH_Usb_Init"));
    api->GetDeviceDescriptor = reinterpret_cast<int32_t (*)(uint64_t, UsbDeviceDescriptor *)>(
        load("OH_Usb_GetDeviceDescriptor"));
    api->GetConfigDescriptor =
        reinterpret_cast<int32_t (*)(uint64_t, uint8_t, UsbDdkConfigDescriptor **)>(
            load("OH_Usb_GetConfigDescriptor"));
    api->FreeConfigDescriptor =
        reinterpret_cast<void (*)(UsbDdkConfigDescriptor *)>(load("OH_Usb_FreeConfigDescriptor"));
    api->ClaimInterface =
        reinterpret_cast<int32_t (*)(uint64_t, uint8_t, uint64_t *)>(load("OH_Usb_ClaimInterface"));
    api->ReleaseInterface =
        reinterpret_cast<int32_t (*)(uint64_t)>(load("OH_Usb_ReleaseInterface"));
    api->SelectInterfaceSetting =
        reinterpret_cast<int32_t (*)(uint64_t, uint8_t)>(load("OH_Usb_SelectInterfaceSetting"));
    api->SendControlReadRequest = reinterpret_cast<int32_t (*)(
        uint64_t, const UsbControlRequestSetup *, uint32_t, uint8_t *, uint32_t *)>(
        load("OH_Usb_SendControlReadRequest"));
    api->SendControlWriteRequest = reinterpret_cast<int32_t (*)(
        uint64_t, const UsbControlRequestSetup *, uint32_t, const uint8_t *, uint32_t)>(
        load("OH_Usb_SendControlWriteRequest"));
    api->SendPipeRequest = reinterpret_cast<int32_t (*)(const UsbRequestPipe *, UsbDeviceMemMap *)>(
        load("OH_Usb_SendPipeRequest"));
    api->CreateDeviceMemMap =
        reinterpret_cast<int32_t (*)(uint64_t, size_t, UsbDeviceMemMap **)>(
            load("OH_Usb_CreateDeviceMemMap"));
    api->DestroyDeviceMemMap =
        reinterpret_cast<void (*)(UsbDeviceMemMap *)>(load("OH_Usb_DestroyDeviceMemMap"));

    // The server drives control transfers and walks config descriptors, so
    // those entry points are load-bearing. GetConfigDescriptor and
    // FreeConfigDescriptor form a pair: a torn table (exactly one present)
    // would crash at first use, reject it outright.
    const bool configPairOk =
        (api->GetConfigDescriptor == nullptr) == (api->FreeConfigDescriptor == nullptr);
    if (api->GetDeviceDescriptor == nullptr || api->ClaimInterface == nullptr ||
        api->SendPipeRequest == nullptr || api->CreateDeviceMemMap == nullptr ||
        api->DestroyDeviceMemMap == nullptr || api->SendControlReadRequest == nullptr ||
        api->SendControlWriteRequest == nullptr || !configPairOk) {
        LOGE("[%{public}s] USB DDK function table incomplete", LOG_TAG);
        dlclose(api->handle);
        return nullptr;
    }
    return api;
}

namespace {

// The DDK requires OH_Usb_Init before any other call. It may already have
// been called by usb_ddk_poller in this process; tolerate that by probing a
// read-only call afterwards. Init is never released here — another module
// may still hold DDK resources.
bool ensureDdkInited(const std::shared_ptr<DdkApi> &ddk) {
    static std::once_flag once;
    static bool ok = false;
    std::call_once(once, [&] {
        if (ddk->Init == nullptr) {
            ok = true; // old DDK without explicit init requirement
            return;
        }
        const int32_t rc = ddk->Init();
        if (rc == 0) {
            ok = true;
            return;
        }
        // Already-initialized (or another quirk): accept when descriptors
        // are still readable. deviceId 0 is never valid, so any result other
        // than INVALID_OPERATION means the DDK layer is up.
        UsbDeviceDescriptor probe{};
        ok = ddk->GetDeviceDescriptor != nullptr &&
             ddk->GetDeviceDescriptor(0, &probe) != 27400002;
        LOGW("[%{public}s] OH_Usb_Init rc=%{public}d, probe-ok=%{public}d", LOG_TAG, rc, ok ? 1 : 0);
    });
    return ok;
}

} // namespace

// ============================================================
// Server
// ============================================================

Server::Server(std::shared_ptr<DdkApi> ddk) : ddk_(std::move(ddk)) {}

Server::~Server() {
    Stop();
}

std::vector<DeviceInfo> Server::devices() const {
    std::lock_guard<std::mutex> lock(devicesMutex_);
    return devices_;
}

void Server::AuthorizePort(uint16_t port) noexcept {
    authorizedPort_.store(port);
}

int Server::Start(std::string *error) {
    if (ddk_ == nullptr) {
        if (error) *error = "USB DDK unavailable";
        return -1;
    }
    if (!ensureDdkInited(ddk_)) {
        if (error) *error = "OH_Usb_Init failed";
        return -1;
    }

    listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd_ < 0) {
        if (error) *error = "socket() failed";
        return -1;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = 0; // ephemeral
    if (::bind(listenFd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
        if (error) *error = "bind() failed";
        ::close(listenFd_);
        listenFd_ = -1;
        return -1;
    }
    if (::listen(listenFd_, 1) < 0) {
        if (error) *error = "listen() failed";
        ::close(listenFd_);
        listenFd_ = -1;
        return -1;
    }
    sockaddr_in bound{};
    socklen_t boundLen = sizeof(bound);
    ::getsockname(listenFd_, reinterpret_cast<sockaddr *>(&bound), &boundLen);
    boundPort_ = ntohs(bound.sin_port);

    running_.store(true);
    acceptThread_ = std::thread([this]() { AcceptLoop(); });
    LOGI("[%{public}s] listening on 127.0.0.1:%{public}d", LOG_TAG, boundPort_);
    return boundPort_;
}

void Server::Stop() noexcept {
    if (!running_.exchange(false)) return;
    {
        // Lifecycle lock: whoever holds it either tears the listener down or
        // publishes the accepted client. If AcceptLoop is past the gate it
        // has already published clientFd_, so the exchange below sees it.
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        if (listenFd_ >= 0) {
            ::shutdown(listenFd_, SHUT_RDWR);
            ::close(listenFd_);
            listenFd_ = -1;
        }
        // Unblock the handler thread: it may be parked in a blocking read on
        // the accepted connection (half a PDU from a stalled remote peer).
        const int client = clientFd_.exchange(-1);
        if (client >= 0) {
            ::shutdown(client, SHUT_RDWR);
        }
    }
    // join outside the lock: the accept thread takes it only around the
    // gate/publish points, never around accept() or HandleConnection().
    if (acceptThread_.joinable()) {
        acceptThread_.join();
    }
    authorizedPort_.store(-1);
}

bool Server::AddDevice(uint32_t busNum, uint32_t devAddress, const std::string &name,
                       std::string *error) {
    // Official encoding (usb_ddk_types.h, Usb_NonRootHubArray).
    const uint64_t deviceId = (uint64_t(busNum) << 32) | uint64_t(devAddress);

    DeviceInfo info;
    info.deviceId = deviceId;
    info.busNum = busNum;
    info.devAddress = devAddress;
    info.busId = "1-" + std::to_string(devAddress);
    info.name = name;
    if (!ReadDescriptors(&info, error)) {
        return false;
    }

    std::lock_guard<std::mutex> lock(devicesMutex_);
    for (auto it = devices_.begin(); it != devices_.end();) {
        if (it->deviceId == deviceId || it->busId == info.busId) {
            it = devices_.erase(it);
        } else {
            ++it;
        }
    }
    devices_.push_back(info);
    LOGI("[%{public}s] registered %{public}s (%{public}s) vid=%{public}04x pid=%{public}04x "
         "ifaces=%{public}zu iso=%{public}d",
         LOG_TAG, info.busId.c_str(), info.name.c_str(), info.vendorId, info.productId,
         info.interfaces.size(), info.hasIsochronous ? 1 : 0);
    return true;
}

void Server::RemoveDevice(const std::string &busId) {
    std::lock_guard<std::mutex> lock(devicesMutex_);
    for (auto it = devices_.begin(); it != devices_.end();) {
        if (it->busId == busId) {
            LOGI("[%{public}s] unregistered %{public}s", LOG_TAG, busId.c_str());
            it = devices_.erase(it);
        } else {
            ++it;
        }
    }
}

bool Server::ReadDescriptors(DeviceInfo *info, std::string *error) {
    UsbDeviceDescriptor desc{};
    if (ddk_->GetDeviceDescriptor(info->deviceId, &desc) != 0) {
        if (error) {
            *error = "GetDeviceDescriptor failed (USB 权限未授予或设备已拔出)";
        }
        return false;
    }
    info->vendorId = desc.idVendor;
    info->productId = desc.idProduct;
    info->bcdDevice = desc.bcdDevice;
    info->klass = desc.bDeviceClass;
    info->subclass = desc.bDeviceSubClass;
    info->protocol = desc.bDeviceProtocol;
    info->numConfigurations = desc.bNumConfigurations ? desc.bNumConfigurations : 1;

    if (ddk_->GetConfigDescriptor == nullptr) {
        return true;
    }
    UsbDdkConfigDescriptor *config = nullptr;
    if (ddk_->GetConfigDescriptor(info->deviceId, 0, &config) != 0 || config == nullptr) {
        // The host cannot attach without the interface list; fail loudly
        // instead of exporting a ghost device.
        if (error) *error = "GetConfigDescriptor failed";
        return false;
    }
    for (uint32_t ii = 0; ii < config->configDescriptor.bNumInterfaces; ++ii) {
        const UsbDdkInterface &ddkIface = config->interface[ii];
        if (ddkIface.numAltsetting == 0 || ddkIface.altsetting == nullptr) {
            continue;
        }
        const UsbDdkInterfaceDescriptor &ddkAlt = ddkIface.altsetting[0];
        DeviceInterface iface{};
        iface.number = ddkAlt.interfaceDescriptor.bInterfaceNumber;
        iface.altSetting = ddkAlt.interfaceDescriptor.bAlternateSetting;
        iface.klass = ddkAlt.interfaceDescriptor.bInterfaceClass;
        iface.subclass = ddkAlt.interfaceDescriptor.bInterfaceSubClass;
        iface.protocol = ddkAlt.interfaceDescriptor.bInterfaceProtocol;
        for (uint32_t jj = 0; jj < ddkAlt.interfaceDescriptor.bNumEndpoints; ++jj) {
            const UsbDdkEndpointDescriptor &ddkEp = ddkAlt.endPoint[jj];
            DeviceEndpoint ep;
            ep.address = ddkEp.endpointDescriptor.bEndpointAddress;
            ep.attributes = ddkEp.endpointDescriptor.bmAttributes;
            ep.maxPacketSize = ddkEp.endpointDescriptor.wMaxPacketSize;
            ep.interval = ddkEp.endpointDescriptor.bInterval;
            iface.endpoints.push_back(ep);
            // attributes & 0x03 == 0x01 means isochronous.
            if ((ep.attributes & 0x03) == 0x01) {
                info->hasIsochronous = true;
            }
        }
        info->interfaces.push_back(iface);
    }
    ddk_->FreeConfigDescriptor(config);
    return true;
}

void Server::AcceptLoop() {
    while (running_.load()) {
        sockaddr_in peer{};
        socklen_t peerLen = sizeof(peer);
        const int fd = ::accept(listenFd_, reinterpret_cast<sockaddr *>(&peer), &peerLen);
        if (fd < 0) break;

        // Loopback + pre-authorized source port only: the exported device
        // must not be reachable by unrelated local processes.
        const uint16_t peerPort = ntohs(peer.sin_port);
        const bool fromLoopback = (ntohl(peer.sin_addr.s_addr) >> 24) == 127;
        const int authorized = authorizedPort_.load();
        if (!fromLoopback || authorized < 0 || peerPort != static_cast<uint16_t>(authorized)) {
            LOGW("[%{public}s] rejected connection from 127.0.0.1:%{public}u (authorized=%{public}d)",
                 LOG_TAG, peerPort, authorized);
            ::close(fd);
            continue;
        }

        // Publish under the lifecycle lock, paired with Stop(): if teardown
        // already began, close the fd here instead of handing it a stale
        // clientFd_ that Stop's exchange would miss (join would then hang
        // until the connection ends on its own).
        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (!running_.load()) {
                ::close(fd);
                break;
            }
            authorizedPort_.store(-1); // one shot: this connection is the tunnel
            // Publish so Stop() can shutdown() the socket out from under a
            // blocking read; retract before close to avoid fd-reuse races.
            clientFd_.store(fd);
        }
        HandleConnection(fd);
        clientFd_.store(-1);
        ::close(fd);
    }
}

void Server::HandleConnection(int fd) {
    using namespace wire;

    // Expect OP_REQ_DEVLIST first (the tunnel's bridge imports directly).
    uint8_t header[kOpCommonSize];
    if (!readAll(fd, header, sizeof(header))) return;
    if (readU16(header) != kVersion) return;
    const uint16_t code = readU16(header + 2);
    if (code == kOpReqDevlist) {
        std::vector<DeviceInfo> list = devices();
        std::vector<uint8_t> reply;
        appendU16(reply, kVersion);
        appendU16(reply, kOpRepDevlist);
        appendU32(reply, 0); // status OK
        appendU32(reply, static_cast<uint32_t>(list.size()));
        for (const auto &dev : list) {
            const std::vector<uint8_t> entry = buildDeviceEntry(dev);
            reply.insert(reply.end(), entry.begin(), entry.end());
            // usbip_usb_interface: class/subclass/protocol + pad.
            for (const auto &iface : dev.interfaces) {
                uint8_t ifaceEntry[4] = { iface.klass, iface.subclass, iface.protocol, 0 };
                reply.insert(reply.end(), ifaceEntry, ifaceEntry + 4);
            }
        }
        if (!writeVec(fd, reply)) return;

        if (!waitReadable(fd, 1000)) return; // list-only client hangs up
        if (!readAll(fd, header, sizeof(header))) return;
        if (readU16(header) != kVersion || readU16(header + 2) != kOpReqImport) return;
    } else if (code != kOpReqImport) {
        return;
    }

    // OP_REQ_IMPORT: 8-byte op_common + 32-byte busid.
    uint8_t busidBuf[kBusIdSize] = {};
    if (!readAll(fd, busidBuf, sizeof(busidBuf))) return;
    const std::string busid(reinterpret_cast<char *>(busidBuf),
                            ::strnlen(reinterpret_cast<char *>(busidBuf), sizeof(busidBuf)));

    DeviceInfo selected{};
    bool found = false;
    for (const auto &dev : devices()) {
        if (dev.busId == busid) {
            selected = dev;
            found = true;
            break;
        }
    }

    if (!found) {
        std::vector<uint8_t> reply;
        appendU16(reply, kVersion);
        appendU16(reply, kOpRepImport);
        appendU32(reply, 1); // ST_NA
        writeVec(fd, reply);
        return;
    }

    ServeImport(fd, selected);
}

bool Server::ServeImport(int clientFd, const DeviceInfo &device) {
    using namespace wire;

    // Claim every interface; the host owns the whole device while attached.
    std::vector<uint64_t> handles;
    for (const auto &iface : device.interfaces) {
        uint64_t handle = 0;
        int32_t rc = ddk_->ClaimInterface(device.deviceId, iface.number, &handle);
        for (int attempt = 1; rc != 0 && attempt <= 3; ++attempt) {
            // usbManager may still be releasing the interface (same race the
            // DDK poller works around).
            usleep(100 * 1000);
            rc = ddk_->ClaimInterface(device.deviceId, iface.number, &handle);
        }
        if (rc != 0) {
            LOGE("[%{public}s] ClaimInterface(%{public}u) failed: %{public}d", LOG_TAG,
                 iface.number, rc);
            for (uint64_t h : handles) {
                if (ddk_->ReleaseInterface) ddk_->ReleaseInterface(h);
            }
            std::vector<uint8_t> reply;
            appendU16(reply, kVersion);
            appendU16(reply, kOpRepImport);
            appendU32(reply, 1); // ST_NA
            writeVec(clientFd, reply);
            return false;
        }
        handles.push_back(handle);
    }
    if (handles.empty()) {
        // Descriptor-less device: nothing the host can drive.
        std::vector<uint8_t> reply;
        appendU16(reply, kVersion);
        appendU16(reply, kOpRepImport);
        appendU32(reply, 1);
        writeVec(clientFd, reply);
        return false;
    }

    std::vector<uint8_t> reply;
    appendU16(reply, kVersion);
    appendU16(reply, kOpRepImport);
    appendU32(reply, 0); // ST_OK
    const std::vector<uint8_t> entry = buildDeviceEntry(device);
    reply.insert(reply.end(), entry.begin(), entry.end());
    if (!writeVec(clientFd, reply)) {
        for (uint64_t h : handles) {
            if (ddk_->ReleaseInterface) ddk_->ReleaseInterface(h);
        }
        return false;
    }
    LOGI("[%{public}s] %{public}s imported (%{public}zu interfaces)", LOG_TAG,
         device.busId.c_str(), handles.size());

    UsbDeviceMemMap *mmap = nullptr;
    const size_t kMmapSize = 64 * 1024;
    if (ddk_->CreateDeviceMemMap(device.deviceId, kMmapSize, &mmap) != 0 || mmap == nullptr) {
        LOGE("[%{public}s] CreateDeviceMemMap failed", LOG_TAG);
        for (uint64_t h : handles) {
            if (ddk_->ReleaseInterface) ddk_->ReleaseInterface(h);
        }
        return false;
    }

    PumpUrbLoop(clientFd, device, handles, mmap);

    ddk_->DestroyDeviceMemMap(mmap);
    for (uint64_t h : handles) {
        if (ddk_->ReleaseInterface) ddk_->ReleaseInterface(h);
    }
    LOGI("[%{public}s] %{public}s released", LOG_TAG, device.busId.c_str());
    return true;
}

void Server::PumpUrbLoop(int clientFd, const DeviceInfo &device,
                         const std::vector<uint64_t> &handles, UsbDeviceMemMap *mmap) {
    using namespace wire;

    // An interrupt/bulk IN URB can wait on the device indefinitely while the
    // host may still send control/OUT traffic. DDK reads run in 200 ms
    // slices; between slices we answer UNLINK for the head URB or suspend it
    // to service queued PDUs, then resume.
    constexpr int kInSliceMs = 200;
    constexpr int kIdlePollMs = 500;
    constexpr uint32_t kControlTimeoutMs = 5000;
    constexpr size_t kMaxControlData = 4096;
    constexpr size_t kMaxPendingIn = 16;

    // Endpoint address / interface number -> owning interface handle (pipe
    // and class-control requests address a claimed interface, not the device).
    std::map<uint8_t, uint64_t> epHandles;
    std::map<uint8_t, uint64_t> ifaceHandles;
    for (size_t i = 0; i < device.interfaces.size() && i < handles.size(); ++i) {
        ifaceHandles[device.interfaces[i].number] = handles[i];
        for (const auto &ep : device.interfaces[i].endpoints) {
            epHandles[ep.address] = handles[i];
        }
    }
    const uint64_t firstHandle = handles.front();
    const auto handleForEp = [&](uint8_t ep) -> uint64_t {
        const auto it = epHandles.find(ep);
        return it != epHandles.end() ? it->second : firstHandle;
    };
    const auto handleForIface = [&](uint8_t iface) -> uint64_t {
        const auto it = ifaceHandles.find(iface);
        return it != ifaceHandles.end() ? it->second : firstHandle;
    };

    const auto sendRetSubmit = [&](uint32_t seqnum, int32_t status, int32_t actual,
                                   const uint8_t *data = nullptr) {
        // usbip_header: command[0] seqnum[4] ... status[20] actual_length[24]
        // start_frame[28] number_of_packets[32] error_count[36]; rest zero.
        // The header reports actual_length regardless; payload bytes exist
        // only when data is provided (OUT replies carry no payload).
        std::vector<uint8_t> ret(kPduHeaderSize + (actual > 0 && data != nullptr ? actual : 0), 0);
        storeU32(ret.data(), kCmdOffset, kRetSubmit);
        storeU32(ret.data(), kSeqnumOffset, seqnum);
        storeI32(ret.data(), kFlagsOrUnlinkTargetOffset, status);
        storeI32(ret.data(), kLenOrActualOffset, actual);
        storeI32(ret.data(), kStartFrameOffset, 0);
        storeI32(ret.data(), kNumPacketsOrErrorOffset, -1); // not isochronous
        storeI32(ret.data(), kErrorCountOffset, 0);
        if (actual > 0 && data != nullptr) {
            std::memcpy(ret.data() + kPduHeaderSize, data, static_cast<size_t>(actual));
        }
        return writeVec(clientFd, ret);
    };
    const auto sendRetUnlink = [&](uint32_t seqnum, int32_t status) {
        std::vector<uint8_t> ret(kPduHeaderSize, 0);
        storeU32(ret.data(), kCmdOffset, kRetUnlink);
        storeU32(ret.data(), kSeqnumOffset, seqnum);
        storeI32(ret.data(), kFlagsOrUnlinkTargetOffset, status);
        return writeVec(clientFd, ret);
    };

    struct PendingIn {
        uint32_t seqnum = 0;
        uint32_t endpoint = 0;
        uint64_t handle = 0;
        int32_t length = 0;
    };
    std::deque<PendingIn> pendingIn;

    enum class Drive { Completed, Suspended, Closed };

    // Executes the head IN URB to completion (or suspension). Only called
    // between DDK slices, so pendingIn mutations by the caller are safe.
    const auto runHeadInUrb = [&]() -> Drive {
        PendingIn &p = pendingIn.front();
        int deviceErrors = 0;
        while (running_.load()) {
            UsbRequestPipe pipe{};
            pipe.interfaceHandle = p.handle;
            pipe.timeout = kInSliceMs;
            pipe.endpoint = static_cast<uint8_t>(p.endpoint & 0xFF);
            mmap->offset = 0;
            mmap->bufferLength = static_cast<uint32_t>(
                p.length > 0 && static_cast<size_t>(p.length) <= mmap->size
                    ? p.length
                    : static_cast<int32_t>(mmap->size));
            mmap->transferedLength = 0;
            const int32_t rc = ddk_->SendPipeRequest(&pipe, mmap);

            if (rc == 0) {
                return sendRetSubmit(p.seqnum, 0,
                                     static_cast<int32_t>(mmap->transferedLength),
                                     mmap->address)
                           ? Drive::Completed
                           : Drive::Closed;
            }
            if (rc == kDdkTimeout) {
                // Slice expired: answer an UNLINK of this URB, otherwise
                // yield to whatever else the host queued.
                if (waitReadable(clientFd, 0)) {
                    uint8_t peek[kPduHeaderSize];
                    const ssize_t peeked = ::recv(clientFd, peek, sizeof(peek), MSG_PEEK);
                    if (peeked == 0) {
                        return Drive::Closed; // orderly EOF
                    }
                    if (peeked == static_cast<ssize_t>(sizeof(peek))) {
                        if (readU32(peek + kCmdOffset) == kCmdUnlink &&
                            readU32(peek + kFlagsOrUnlinkTargetOffset) == p.seqnum) {
                            uint8_t pdu[kPduHeaderSize];
                            if (!readAll(clientFd, pdu, sizeof(pdu))) return Drive::Closed;
                            // Head URB is still pending (no RET_SUBMIT yet):
                            // report it as canceled, like a real unlinked URB.
                            return sendRetUnlink(readU32(pdu + kSeqnumOffset),
                                                 kUsbErrConnreset)
                                       ? Drive::Completed
                                       : Drive::Closed;
                        }
                        return Drive::Suspended; // some other full PDU queued
                    }
                    if (peeked > 0) {
                        // TCP delivered only part of the header; a live peer
                        // is mid-PDU. Hand off to the main loop's blocking
                        // readAll, which completes it (and is unbounded only
                        // until Stop() shuts the socket down).
                        return Drive::Suspended;
                    }
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        continue; // spurious readability: keep waiting
                    }
                    return Drive::Closed; // hard socket error
                }
                continue; // no news from the host: keep waiting on the device
            }
            // Real device error (detached, babble...). A short burst is
            // tolerated; a sustained one ends the URB and the connection so
            // the tunnel surfaces the failure instead of black-holing URBs.
            if (++deviceErrors < 3) {
                usleep(20 * 1000);
                continue;
            }
            LOGE("[%{public}s] IN ep 0x%{public}02x failed rc=%{public}d, closing", LOG_TAG,
                 pipe.endpoint, rc);
            sendRetSubmit(p.seqnum, kUsbErrIo, 0);
            return Drive::Closed;
        }
        // Stop() while a URB is outstanding: complete it as unlinked.
        sendRetUnlink(p.seqnum, 0);
        return Drive::Closed;
    };

    // Handles one 48-byte PDU already read off the socket.
    // Returns false when the connection must close.
    const auto processPdu = [&](const uint8_t pdu[kPduHeaderSize]) -> bool {
        const uint32_t cmd = readU32(pdu + kCmdOffset);
        const uint32_t seqnum = readU32(pdu + kSeqnumOffset);
        const uint32_t direction = readU32(pdu + kDirectionOffset);
        const uint32_t endpoint = readU32(pdu + kEpOffset);

        if (cmd == kCmdSubmit) {
            const int32_t transferLength = readI32(pdu + kLenOrActualOffset);
            (void)readU32(pdu + kFlagsOrUnlinkTargetOffset); // transfer_flags
            (void)readI32(pdu + kIntervalOffset);            // interval

            if (endpoint == 0) {
                // Control transfer: setup[8] lives in the PDU itself.
                UsbControlRequestSetup setup{};
                setup.bmRequestType = pdu[kSetupOffset];
                setup.bRequest = pdu[kSetupOffset + 1];
                setup.wValue = readUsbU16(pdu + kSetupOffset + 2);
                setup.wIndex = readUsbU16(pdu + kSetupOffset + 4);
                setup.wLength = readUsbU16(pdu + kSetupOffset + 6);

                // Class requests carry the target interface in wIndex.
                const uint64_t handle =
                    handleForIface(static_cast<uint8_t>(setup.wIndex & 0xFF));

                const bool isIn = (setup.bmRequestType & 0x80) != 0;
                uint8_t data[kMaxControlData] = {};
                int32_t rc = 0;
                int32_t actual = 0;
                if (isIn) {
                    if (setup.wLength > kMaxControlData) {
                        return sendRetSubmit(seqnum, kUsbErrOverflow, 0);
                    }
                    uint32_t got = setup.wLength;
                    rc = ddk_->SendControlReadRequest(handle, &setup, kControlTimeoutMs,
                                                      data, &got);
                    if (rc != 0) {
                        LOGW("[%{public}s] control IN request=0x%{public}02x value=0x%{public}04x "
                             "index=0x%{public}04x length=%{public}u DDK rc=%{public}d",
                             LOG_TAG, setup.bRequest, setup.wValue, setup.wIndex, setup.wLength, rc);
                    }
                    actual = (rc == 0) ? static_cast<int32_t>(got) : 0;
                    if (rc == kDdkTimeout) rc = kUsbErrTimedout;
                    else if (rc != 0) rc = kUsbErrIo;
                    return sendRetSubmit(seqnum, rc, actual, data);
                }
                int32_t len = transferLength > 0 ? transferLength : 0;
                if (static_cast<size_t>(len) > kMaxControlData) {
                    return sendRetSubmit(seqnum, kUsbErrOverflow, 0);
                }
                if (len > 0 && !readAll(clientFd, data, static_cast<size_t>(len))) {
                    return false;
                }
                rc = ddk_->SendControlWriteRequest(handle, &setup, kControlTimeoutMs,
                                                   data, static_cast<uint32_t>(len));
                if (rc != 0) {
                    LOGW("[%{public}s] control OUT request=0x%{public}02x value=0x%{public}04x "
                         "index=0x%{public}04x length=%{public}u DDK rc=%{public}d",
                         LOG_TAG, setup.bRequest, setup.wValue, setup.wIndex, setup.wLength, rc);
                }
                if (rc == kDdkTimeout) rc = kUsbErrTimedout;
                else if (rc != 0) rc = kUsbErrIo;
                return sendRetSubmit(seqnum, rc, rc == 0 ? len : 0);
            }

            // Bulk / interrupt transfer.
            const bool isIn = (direction == 1);
            // USB/IP ep is a number; DDK and descriptor lookup need a USB
            // endpoint address, including bit 7 for an IN transfer.
            const uint8_t epAddr = static_cast<uint8_t>((endpoint & 0x0F) | (isIn ? 0x80 : 0));
            const uint64_t handle = handleForEp(epAddr);

            if (isIn) {
                if (pendingIn.size() >= kMaxPendingIn) {
                    return sendRetSubmit(seqnum, kUsbErrIo, 0);
                }
                PendingIn p;
                p.seqnum = seqnum;
                p.endpoint = epAddr;
                p.handle = handle;
                p.length = transferLength;
                pendingIn.push_back(std::move(p));
                return true;
            }

            // OUT: body follows the header; send through the mmap in chunks
            // (HID writes are tiny, but stay correct up to 1 MB).
            int32_t len = transferLength > 0 ? transferLength : 0;
            if (len > 1024 * 1024) {
                return sendRetSubmit(seqnum, kUsbErrOverflow, 0);
            }
            std::vector<uint8_t> data(static_cast<size_t>(len));
            if (len > 0 && !readAll(clientFd, data.data(), data.size())) {
                return false;
            }
            int32_t status = 0;
            size_t sent = 0;
            while (sent < data.size()) {
                const size_t chunk = std::min(data.size() - sent, mmap->size);
                std::memcpy(mmap->address, data.data() + sent, chunk);
                mmap->offset = 0;
                mmap->bufferLength = static_cast<uint32_t>(chunk);
                mmap->transferedLength = 0;
                UsbRequestPipe pipe{};
                pipe.interfaceHandle = handle;
                pipe.timeout = kControlTimeoutMs;
                pipe.endpoint = epAddr;
                const int32_t rc = ddk_->SendPipeRequest(&pipe, mmap);
                if (rc != 0) {
                    status = (rc == kDdkTimeout) ? kUsbErrTimedout : kUsbErrIo;
                    break;
                }
                sent += chunk;
            }
            return sendRetSubmit(seqnum, status,
                                 status == 0 ? static_cast<int32_t>(data.size()) : 0);
        }

        if (cmd == kCmdUnlink) {
            // Payload field at [20] names the URB to unlink.
            const uint32_t target = readU32(pdu + kFlagsOrUnlinkTargetOffset);
            for (auto it = pendingIn.begin(); it != pendingIn.end(); ++it) {
                if (it->seqnum == target) {
                    // Still pending (no RET_SUBMIT sent): report it as
                    // canceled, mirroring a real unlinked URB's status.
                    pendingIn.erase(it);
                    return sendRetUnlink(seqnum, kUsbErrConnreset);
                }
            }
            // Already completed: ENOENT, mirroring the kernel stub.
            return sendRetUnlink(seqnum, kUsbErrNoent);
        }

        LOGW("[%{public}s] unknown PDU cmd %{public}u, closing", LOG_TAG, cmd);
        return false;
    };

    while (running_.load()) {
        // Drive queued IN URBs; Suspended means a PDU is waiting and takes
        // priority below before the head URB resumes.
        if (!pendingIn.empty()) {
            const Drive d = runHeadInUrb();
            if (d == Drive::Closed) return;
            if (d == Drive::Completed) {
                pendingIn.pop_front();
                continue;
            }
            // Suspended: the queued PDU is readable right now.
            uint8_t pdu[kPduHeaderSize];
            if (!readAll(clientFd, pdu, sizeof(pdu))) return;
            if (!processPdu(pdu)) return;
            continue;
        }

        if (!waitReadable(clientFd, kIdlePollMs)) continue;
        uint8_t pdu[kPduHeaderSize];
        if (!readAll(clientFd, pdu, sizeof(pdu))) return;
        if (!processPdu(pdu)) return;
    }
}

} // namespace usbip
