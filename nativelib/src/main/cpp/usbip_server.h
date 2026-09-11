/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * usbip_server - In-app USB/IP server backed by the HarmonyOS USB DDK.
 *
 * Speaks the standard USB/IP 1.1.1 server protocol on a loopback TCP port,
 * exactly as the reverse tunnel expects: Moonlight's tunnel client connects
 * to 127.0.0.1:<port>, Sunshine's usbip-win2 attaches through it.
 *
 * Device model: OH_Usb_GetDevices() returns an empty list for normal apps,
 * so devices are registered from the ArkTS usbManager layer as
 * (busNum, devAddress) pairs. The DDK deviceId is derived with the official
 * encoding (busNum << 32 | devAddress, see Usb_NonRootHubArray in
 * usb_ddk_types.h) and validated via OH_Usb_GetDeviceDescriptor.
 *
 * Only the tunnel's own loopback source port may talk to the server
 * (mirrors Android's NativeUsbIp.authorizeLocalConnection): other processes
 * on the device must not be able to drive the exported USB device.
 *
 * Supported (v1 boundary, consistent with usbipd-win/usbip-win2):
 *   - OP_REQ_DEVLIST / OP_REQ_IMPORT handshake
 *   - Control transfers (via OH_Usb_SendControlRead/WriteRequest)
 *   - Bulk and interrupt transfers (via OH_Usb_SendPipeRequest)
 *   - URB submit / unlink with RET_SUBMIT / RET_UNLINK
 *   - One device per connection (USB/IP model)
 *
 * Not supported: isochronous endpoints (DDK does not expose them).
 */

#ifndef USBIP_SERVER_H
#define USBIP_SERVER_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <thread>

#include <napi/native_api.h>
#include <usb/usb_ddk_api.h>
#include <usb/usb_ddk_types.h>

namespace usbip {

// ============================================================
// USB DDK function pointers (dlopen'd, same pattern as usb_ddk_poller)
// ============================================================

struct DdkApi {
    int32_t (*Init)(void) = nullptr;
    void (*Release)(void) = nullptr;
    int32_t (*GetDeviceDescriptor)(uint64_t, struct UsbDeviceDescriptor *) = nullptr;
    int32_t (*GetConfigDescriptor)(uint64_t, uint8_t, struct UsbDdkConfigDescriptor **) = nullptr;
    void (*FreeConfigDescriptor)(struct UsbDdkConfigDescriptor *) = nullptr;
    int32_t (*ClaimInterface)(uint64_t, uint8_t, uint64_t *) = nullptr;
    int32_t (*ReleaseInterface)(uint64_t) = nullptr;
    int32_t (*SelectInterfaceSetting)(uint64_t, uint8_t) = nullptr;
    int32_t (*SendControlReadRequest)(uint64_t, const struct UsbControlRequestSetup *,
                                      uint32_t, uint8_t *, uint32_t *) = nullptr;
    int32_t (*SendControlWriteRequest)(uint64_t, const struct UsbControlRequestSetup *,
                                       uint32_t, const uint8_t *, uint32_t) = nullptr;
    int32_t (*SendPipeRequest)(const struct UsbRequestPipe *, struct UsbDeviceMemMap *) = nullptr;
    int32_t (*CreateDeviceMemMap)(uint64_t, size_t, struct UsbDeviceMemMap **) = nullptr;
    void (*DestroyDeviceMemMap)(struct UsbDeviceMemMap *) = nullptr;
    void *handle = nullptr;
};

// dlopen("libusb_ndk.z.so") + dlsym. Returns nullptr on failure.
std::shared_ptr<DdkApi> LoadDdk();

// ============================================================
// Device model (what DEVLIST reports)
// ============================================================

struct DeviceEndpoint {
    uint8_t address = 0;    // includes direction bit
    uint8_t attributes = 0; // transfer type bits 0..2
    uint16_t maxPacketSize = 0;
    uint8_t interval = 0;
};

struct DeviceInterface {
    uint8_t number = 0;
    uint8_t altSetting = 0;
    uint8_t klass = 0;
    uint8_t subclass = 0;
    uint8_t protocol = 0;
    std::vector<DeviceEndpoint> endpoints;
};

struct DeviceInfo {
    uint64_t deviceId = 0;    // DDK device id: busNum << 32 | devAddress
    uint32_t busNum = 0;
    uint32_t devAddress = 0;
    std::string busId;        // synthetic "1-<devAddress>" for the wire protocol
    std::string name;         // display name from usbManager (logging only)
    uint16_t vendorId = 0;
    uint16_t productId = 0;
    uint16_t bcdDevice = 0;
    uint8_t klass = 0;
    uint8_t subclass = 0;
    uint8_t protocol = 0;
    uint8_t numConfigurations = 1;
    uint8_t speed = 3;        // USB_SPEED_HIGH
    std::vector<DeviceInterface> interfaces;
    bool hasIsochronous = false;
};

// ============================================================
// Server — one thread, one listening socket, one device per connection
// ============================================================

class Server {
public:
    explicit Server(std::shared_ptr<DdkApi> ddk);
    ~Server();

    // Bind + listen on loopback (port 0 = ephemeral). Returns the bound port,
    // or -1 with *error set.
    int Start(std::string *error);
    void Stop() noexcept;
    bool IsRunning() const noexcept { return running_.load(); }
    int BoundPort() const noexcept { return boundPort_; }

    // Register a usbManager device. Validates the derived DDK deviceId and
    // reads its descriptors. Returns false with *error set when the device
    // cannot be accessed through the DDK.
    bool AddDevice(uint32_t busNum, uint32_t devAddress, const std::string &name,
                   std::string *error);
    void RemoveDevice(const std::string &busId);
    std::vector<DeviceInfo> devices() const;

    // Restricts the next accepted connection to this loopback source port.
    // The tunnel binds its local socket first and authorizes itself here.
    void AuthorizePort(uint16_t port) noexcept;

private:
    void AcceptLoop();
    void HandleConnection(int clientFd);
    bool ReadDescriptors(DeviceInfo *info, std::string *error);
    bool ServeImport(int clientFd, const DeviceInfo &device);
    void PumpUrbLoop(int clientFd, const DeviceInfo &device,
                     const std::vector<uint64_t> &handles, struct UsbDeviceMemMap *mmap);

    std::shared_ptr<DdkApi> ddk_;
    int listenFd_ = -1;
    int boundPort_ = 0;
    std::atomic<bool> running_{false};
    std::atomic<int> authorizedPort_{-1};
    // Accepted connection owned by the accept thread; published so Stop()
    // can shutdown() it and unblock any read the handler is stuck in.
    std::atomic<int> clientFd_{-1};
    std::thread acceptThread_;
    mutable std::mutex devicesMutex_;
    std::vector<DeviceInfo> devices_;
};

} // namespace usbip

#endif // USBIP_SERVER_H
