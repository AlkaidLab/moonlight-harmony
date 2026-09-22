// Linux host integration test: real USB/IP sockets and production Server,
// injected DDK functions (no physical USB device or HarmonyOS SDK required).
#include "usbip_server.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <array>
#include <cstring>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
void be32(uint8_t *p, uint32_t v) {
    for (int i = 3; i >= 0; --i) { p[i] = v & 255; v >>= 8; }
}
uint32_t read32(const uint8_t *p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
void sendBytes(int fd, const uint8_t *p, size_t n) {
    while (n) {
        const auto sent = send(fd, p, n, MSG_NOSIGNAL);
        require(sent > 0, "socket write failed");
        p += sent; n -= sent;
    }
}
void recvBytes(int fd, uint8_t *p, size_t n) {
    while (n) {
        const auto got = recv(fd, p, n, 0);
        require(got > 0, "socket read failed/timed out");
        p += got; n -= got;
    }
}
std::shared_ptr<usbip::DdkApi> mockDdk() {
    auto ddk = std::make_shared<usbip::DdkApi>();
    ddk->Init = []() -> int32_t { return 0; };
    ddk->GetDeviceDescriptor = [](uint64_t, UsbDeviceDescriptor *d) -> int32_t {
        *d = {0x054c, 0x0ce6, 0x100, 0, 0, 0, 1}; return 0;
    };
    ddk->GetConfigDescriptor = [](uint64_t, uint8_t, UsbDdkConfigDescriptor **out) -> int32_t {
        // A second interface ensures endpoint ownership, not just its direction,
        // is checked. IN 4 belongs to interface 3, OUT 3 to interface 0.
        static UsbDdkEndpointDescriptor endpoints[] = {{{0x03, 3, 64, 1}}, {{0x84, 3, 64, 1}}};
        static UsbDdkInterfaceDescriptor alts[] = {{{0, 0, 3, 0, 0, 1}, &endpoints[0]},
                                                   {{3, 0, 3, 0, 0, 1}, &endpoints[1]}};
        static UsbDdkInterface ifaces[] = {{1, &alts[0]}, {1, &alts[1]}};
        static UsbDdkConfigDescriptor config = {{2}, ifaces};
        *out = &config; return 0;
    };
    ddk->FreeConfigDescriptor = [](UsbDdkConfigDescriptor *) {};
    ddk->ClaimInterface = [](uint64_t, uint8_t iface, uint64_t *h) -> int32_t {
        *h = 100 + iface; return 0;
    };
    ddk->ReleaseInterface = [](uint64_t) -> int32_t { return 0; };
    ddk->CreateDeviceMemMap = [](uint64_t, size_t size, UsbDeviceMemMap **out) -> int32_t {
        *out = new UsbDeviceMemMap{new uint8_t[size], size, 0, 0, 0}; return 0;
    };
    ddk->DestroyDeviceMemMap = [](UsbDeviceMemMap *m) { delete[] m->address; delete m; };
    ddk->SendControlReadRequest = [](uint64_t h, const UsbControlRequestSetup *s,
                                    uint32_t, uint8_t *data, uint32_t *len) -> int32_t {
        if (h != 100 || s->bmRequestType != 0x80 || s->bRequest != 6 ||
            s->wValue != 0x0100 || s->wIndex != 0 || s->wLength != 18 || *len < 18) return -1;
        const uint8_t descriptor[] = {18,1,0,2,0,0,0,64,0x4c,0x05,0xe6,0x0c,0,1,1,2,0,1};
        std::memcpy(data, descriptor, 18); *len = 18; return 0;
    };
    ddk->SendControlWriteRequest = [](uint64_t h, const UsbControlRequestSetup *s,
                                     uint32_t, const uint8_t *data, uint32_t len) -> int32_t {
        return h == 103 && s->bmRequestType == 0x21 && s->bRequest == 9 &&
               s->wValue == 0x0205 && s->wIndex == 3 && s->wLength == 2 &&
               len == 2 && data[0] == 5 && data[1] == 0xaa ? 0 : -1;
    };
    ddk->SendPipeRequest = [](const UsbRequestPipe *p, UsbDeviceMemMap *m) -> int32_t {
        if (p->endpoint == 0x84 && p->interfaceHandle == 103) {
            m->address[0] = 0x01; m->address[1] = 0x7f; m->transferedLength = 2; return 0;
        }
        if (p->endpoint == 0x03 && p->interfaceHandle == 100 &&
            m->bufferLength == 2 && m->address[0] == 0x02 && m->address[1] == 0xaa) {
            m->transferedLength = 2; return 0;
        }
        return -1;
    };
    return ddk;
}
struct Fixture {
    usbip::Server server{mockDdk()};
    int fd = -1;
    Fixture() {
        std::string error;
        const int port = server.Start(&error);
        require(port > 0, "server start failed");
        require(server.AddDevice(2, 2, "DualSense", &error), "device registration failed");
        fd = socket(AF_INET, SOCK_STREAM, 0);
        require(fd >= 0, "socket failed");
        timeval timeout{2, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        sockaddr_in local{}; local.sin_family = AF_INET; local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        require(bind(fd, reinterpret_cast<sockaddr *>(&local), sizeof(local)) == 0, "bind failed");
        socklen_t size = sizeof(local);
        require(getsockname(fd, reinterpret_cast<sockaddr *>(&local), &size) == 0, "getsockname failed");
        server.AuthorizePort(ntohs(local.sin_port));
        local.sin_port = htons(port);
        require(connect(fd, reinterpret_cast<sockaddr *>(&local), sizeof(local)) == 0, "connect failed");
        std::array<uint8_t, 40> request{};
        request[0] = 1; request[1] = 0x11; request[2] = 0x80; request[3] = 3;
        std::memcpy(request.data() + 8, "1-2", 3);
        sendBytes(fd, request.data(), request.size());
        std::array<uint8_t, 320> reply{};
        recvBytes(fd, reply.data(), reply.size());
        require(read32(reply.data() + 4) == 0, "import failed");
    }
    ~Fixture() { if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); } server.Stop(); }
    std::vector<uint8_t> submit(uint32_t direction, uint32_t ep, uint32_t length,
                               std::array<uint8_t, 8> setup = {}, std::vector<uint8_t> payload = {}) {
        std::array<uint8_t, 48> pdu{};
        be32(pdu.data(), 1); be32(pdu.data() + 4, 42);
        be32(pdu.data() + 8, 0x00020002); be32(pdu.data() + 12, direction);
        be32(pdu.data() + 16, ep); be32(pdu.data() + 24, length);
        be32(pdu.data() + 32, 0xffffffff);
        std::memcpy(pdu.data() + 40, setup.data(), setup.size());
        sendBytes(fd, pdu.data(), pdu.size());
        if (!payload.empty()) sendBytes(fd, payload.data(), payload.size());
        recvBytes(fd, pdu.data(), pdu.size());
        require(read32(pdu.data()) == 3 && read32(pdu.data() + 4) == 42, "bad reply header");
        const int32_t status = static_cast<int32_t>(read32(pdu.data() + 20));
        if (status) throw std::runtime_error("RET_SUBMIT status=" + std::to_string(status));
        const uint32_t actual = read32(pdu.data() + 24);
        require(actual <= length, "reply exceeds requested length");
        std::vector<uint8_t> data(direction == 1 ? actual : 0);
        if (!data.empty()) recvBytes(fd, data.data(), data.size());
        return data;
    }
};
} // namespace
int main() {
    int failures = 0;
    const auto test = [&](const char *name, auto run) {
        try { Fixture f; run(f); std::cout << "PASS " << name << '\n'; }
        catch (const std::exception &e) { ++failures; std::cout << "FAIL " << name << ": " << e.what() << '\n'; }
    };
    test("GET_DESCRIPTOR 18-byte little-endian setup", [](Fixture &f) {
        const auto data = f.submit(1, 0, 18, {0x80,6,0,1,0,0,18,0});
        require(data.size() == 18 && data[0] == 18 && data[1] == 1 && data[8] == 0x4c,
                "incorrect device descriptor");
    });
    test("SET_REPORT value/index/length and interface routing", [](Fixture &f) {
        f.submit(0, 0, 2, {0x21,9,5,2,3,0,2,0}, {5,0xaa});
    });
    test("interrupt IN endpoint 4 routes to address 0x84/interface 3", [](Fixture &f) {
        const auto data = f.submit(1, 4, 64);
        require(data == std::vector<uint8_t>({1,0x7f}), "input report lost");
    });
    test("interrupt OUT endpoint 3 stays address 0x03", [](Fixture &f) {
        f.submit(0, 3, 2, {}, {2,0xaa});
    });
    return failures ? 1 : 0;
}
