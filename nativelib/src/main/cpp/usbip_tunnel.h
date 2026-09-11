/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * usbip_tunnel - Reverse USB/IP tunnel client (HarmonyOS native port).
 *
 * Port of moonlight-qt's UsbForwarding::Tunnel. Connects a local USB/IP
 * server (usbip::Server on 127.0.0.1) to Sunshine's TLS endpoint with a
 * one-line JSON handshake, then pumps opaque bytes in both directions.
 *
 * Wire contract (docs/remote-usb-reverse-tunnel.md, Sunshine
 * reverse_tunnel_service.cpp):
 *   C → S: {"op":"forward","token":"<token>","busid":"1-2"}\n
 *   S → C: {"op":"ready"}\n   or   {"op":"error","reason":"..."}\n
 *           (then raw USB/IP bytes after "ready")
 *
 * TLS mirrors the qt/Android clients: chain/hostname verification stays off,
 * and the peer certificate must DER-match the certificate pinned at pairing
 * time. The paired client certificate authenticates us to Sunshine.
 */

#ifndef USBIP_TUNNEL_H
#define USBIP_TUNNEL_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>

namespace usbip {

struct TunnelConfig {
    std::string host;               // Sunshine address
    uint16_t port = 47996;          // from /api/v1/usb-forwarding capability
    std::string sessionToken;       // one-shot token from the same endpoint
    std::string clientCertPem;      // paired client certificate
    std::string clientKeyPem;       // paired client private key
    std::string serverCertPem;      // pin target (paired server certificate)
    std::string localHost = "127.0.0.1";
    uint16_t localPort = 3240;      // usbip::Server port
    std::string localBusId;         // busid to forward (e.g. "1-1")

    // Called on the tunnel thread with the bound loopback source port right
    // after the local socket is bound, before either connect. The default
    // USB DDK server uses it to lock the listener to this tunnel.
    std::function<void(uint16_t)> onLocalBound;
};

class Tunnel {
public:
    using StateCallback = std::function<void(const char *state, const char *message)>;

    explicit Tunnel(TunnelConfig config);
    ~Tunnel();

    // Connects both sockets asynchronously; state is reported through the
    // callback on the tunnel thread: "connecting", "ready", "closed",
    // "error". After "ready" the pump moves USB/IP bytes verbatim.
    void Start(StateCallback onState);
    void Stop() noexcept; // thread-safe; unblocks the pump via shutdown()

    bool IsValid() const;

private:
    void Run();                    // thread body
    void Pump(int localFd, void *ssl);
    void Fail(const std::string &msg);
    void WakeSockets() noexcept;

    TunnelConfig config_;
    StateCallback onState_;
    std::atomic<bool> running_{false};
    std::atomic<bool> finished_{false};
    std::thread thread_;
    // fds are published as soon as they exist so Stop() can shutdown() them
    // and unblock a connect/handshake/pump in progress. -1 = not yet open.
    std::atomic<int> localFd_{-1};
    std::atomic<int> remoteFd_{-1};
    void *sslCtx_ = nullptr;       // SSL_CTX*, void* to avoid header leak
};

} // namespace usbip

#endif // USBIP_TUNNEL_H
