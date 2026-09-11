/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * usbip_tunnel.cpp - Reverse tunnel client, native port from moonlight-qt.
 */

#include "usbip_tunnel.h"

#include <cstring>
#include <thread>

#include <dlfcn.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <arpa/inet.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#define LOG_TAG "UsbIpTunnel"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace usbip {

namespace {

constexpr int kConnectTimeoutSec = 10;
constexpr int kHandshakeTimeoutSec = 15;
constexpr size_t kMaxHandshakeBytes = 4096;
constexpr size_t kIoBufferSize = 64 * 1024;

bool WriteAllPlain(int fd, const uint8_t *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        const ssize_t n = ::write(fd, data + off, len - off);
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

bool ReadAllPlain(int fd, uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        const ssize_t n = ::read(fd, buf + off, len - off);
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

int ConnectTcp(const std::string &host, uint16_t port, int timeoutSec) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    // Non-blocking connect with timeout.
    const int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr(host.c_str());

    const int rc = ::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        ::close(fd);
        return -1;
    }
    if (rc != 0) {
        pollfd pfd{fd, POLLOUT, 0};
        if (::poll(&pfd, 1, timeoutSec * 1000) <= 0) {
            ::close(fd);
            return -1;
        }
        int err = 0;
        socklen_t errLen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen);
        if (err != 0) {
            ::close(fd);
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags); // back to blocking

    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
    return fd;
}

// Extracts "reason":"..." from a compact JSON error line (no parser needed
// for this fixed contract; result is truncated for the UI).
std::string extractReason(const std::string &line) {
    const size_t key = line.find("\"reason\"");
    if (key == std::string::npos) return line.substr(0, 120);
    const size_t colon = line.find(':', key);
    if (colon == std::string::npos) return line.substr(0, 120);
    size_t start = line.find('"', colon);
    if (start == std::string::npos) return line.substr(0, 120);
    ++start;
    const size_t end = line.find('"', start);
    return line.substr(start, (end == std::string::npos ? line.size() : end) - start);
}

} // namespace

Tunnel::Tunnel(TunnelConfig config) : config_(std::move(config)) {}

Tunnel::~Tunnel() {
    Stop();
}

bool Tunnel::IsValid() const {
    return !config_.host.empty() && config_.port != 0 &&
           !config_.sessionToken.empty() && !config_.clientCertPem.empty() &&
           !config_.clientKeyPem.empty() && !config_.serverCertPem.empty() &&
           !config_.localBusId.empty() && config_.localPort != 0;
}

void Tunnel::Start(StateCallback onState) {
    onState_ = std::move(onState);
    running_.store(true);
    finished_.store(false);
    localFd_.store(-1);
    remoteFd_.store(-1);
    thread_ = std::thread([this]() { Run(); });
}

void Tunnel::Stop() noexcept {
    running_.store(false);
    WakeSockets();
    if (thread_.joinable()) {
        thread_.join();
    }
    if (sslCtx_ != nullptr) {
        SSL_CTX_free(reinterpret_cast<SSL_CTX *>(sslCtx_));
        sslCtx_ = nullptr;
    }
}

void Tunnel::WakeSockets() noexcept {
    // shutdown() is idempotent; it turns any blocking connect/read/write on
    // these sockets into an error so Run() unwinds promptly. Run() owns the
    // close() calls on its own copies.
    const int local = localFd_.load();
    const int remote = remoteFd_.load();
    if (local >= 0) ::shutdown(local, SHUT_RDWR);
    if (remote >= 0) ::shutdown(remote, SHUT_RDWR);
}

void Tunnel::Fail(const std::string &msg) {
    LOGE("[%{public}s] %{public}s", LOG_TAG, msg.c_str());
    if (finished_.exchange(true)) return;
    if (onState_) onState_("error", msg.c_str());
}

void Tunnel::Run() {
    if (onState_) onState_("connecting", "");

    // Reserve the loopback source port first so the USB DDK server can lock
    // its listener to exactly this tunnel before any bytes flow.
    const int localFd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (localFd < 0) {
        Fail("local socket creation failed");
        return;
    }
    localFd_.store(localFd);
    {
        sockaddr_in bindAddr{};
        bindAddr.sin_family = AF_INET;
        bindAddr.sin_addr.s_addr = inet_addr(config_.localHost.c_str());
        bindAddr.sin_port = 0;
        if (::bind(localFd, reinterpret_cast<sockaddr *>(&bindAddr), sizeof(bindAddr)) < 0) {
            Fail("local bind failed");
            ::close(localFd);
            localFd_.store(-1);
            return;
        }
        sockaddr_in bound{};
        socklen_t boundLen = sizeof(bound);
        ::getsockname(localFd, reinterpret_cast<sockaddr *>(&bound), &boundLen);
        if (config_.onLocalBound) {
            config_.onLocalBound(ntohs(bound.sin_port));
        }
    }

    const int remoteFd = ConnectTcp(config_.host, config_.port, kConnectTimeoutSec);
    if (remoteFd < 0) {
        Fail("Sunshine connect failed: " + config_.host + ":" + std::to_string(config_.port));
        ::close(localFd);
        localFd_.store(-1);
        return;
    }
    remoteFd_.store(remoteFd);

    // Bound read timeout for the whole startup phase (TLS + JSON + attach).
    timeval tv{ kHandshakeTimeoutSec, 0 };
    setsockopt(remoteFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (ctx == nullptr) {
        Fail("SSL_CTX_new failed");
        ::close(localFd);
        ::close(remoteFd);
        localFd_.store(-1);
        remoteFd_.store(-1);
        return;
    }
    sslCtx_ = ctx;

    // Paired client identity.
    {
        BIO *certBio = BIO_new_mem_buf(config_.clientCertPem.data(),
                                       static_cast<int>(config_.clientCertPem.size()));
        BIO *keyBio = BIO_new_mem_buf(config_.clientKeyPem.data(),
                                      static_cast<int>(config_.clientKeyPem.size()));
        X509 *cert = certBio ? PEM_read_bio_X509(certBio, nullptr, nullptr, nullptr) : nullptr;
        EVP_PKEY *key = keyBio ? PEM_read_bio_PrivateKey(keyBio, nullptr, nullptr, nullptr) : nullptr;
        if (cert == nullptr || key == nullptr ||
            SSL_CTX_use_certificate(ctx, cert) != 1 ||
            SSL_CTX_use_PrivateKey(ctx, key) != 1) {
            if (cert) X509_free(cert);
            if (key) EVP_PKEY_free(key);
            if (certBio) BIO_free(certBio);
            if (keyBio) BIO_free(keyBio);
            Fail("failed to load paired client certificate/key");
            ::close(localFd);
            ::close(remoteFd);
            localFd_.store(-1);
            remoteFd_.store(-1);
            return;
        }
        X509_free(cert);
        EVP_PKEY_free(key);
        BIO_free(certBio);
        BIO_free(keyBio);
    }

    // Chain/hostname verification cannot express "trust exactly this paired
    // self-signed certificate" (mirrors nvhttp and the qt/Android tunnels):
    // verify manually by comparing DER below.
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nullptr);

    X509 *pinned = nullptr;
    {
        BIO *pinBio = BIO_new_mem_buf(config_.serverCertPem.data(),
                                      static_cast<int>(config_.serverCertPem.size()));
        pinned = pinBio ? PEM_read_bio_X509(pinBio, nullptr, nullptr, nullptr) : nullptr;
        if (pinBio) BIO_free(pinBio);
    }
    if (pinned == nullptr) {
        Fail("failed to load pinned server certificate");
        ::close(localFd);
        ::close(remoteFd);
        localFd_.store(-1);
        remoteFd_.store(-1);
        return;
    }

    SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, remoteFd);

    bool ok = true;
    if (SSL_connect(ssl) != 1) {
        unsigned long err = ERR_get_error();
        char buf[256];
        ERR_error_string_n(err, buf, sizeof(buf));
        Fail(std::string("TLS handshake failed: ") + buf);
        ok = false;
    } else {
        X509 *peer = SSL_get1_peer_certificate(ssl);
        if (peer == nullptr) {
            Fail("TLS peer did not present a certificate");
            ok = false;
        } else if (X509_cmp(peer, pinned) != 0) {
            X509_free(peer);
            Fail("server certificate does not match the pairing pin");
            ok = false;
        } else {
            X509_free(peer);
        }
    }
    X509_free(pinned);
    if (!ok) {
        SSL_free(ssl);
        ::close(localFd);
        ::close(remoteFd);
        localFd_.store(-1);
        remoteFd_.store(-1);
        return;
    }
    LOGI("[%{public}s] TLS established with %{public}s:%{public}u", LOG_TAG,
         config_.host.c_str(), config_.port);

    // One-line JSON handshake, then opaque USB/IP bytes.
    {
        const std::string line = "{\"op\":\"forward\",\"token\":\"" + config_.sessionToken +
                                 "\",\"busid\":\"" + config_.localBusId + "\"}\n";
        if (SSL_write(ssl, line.data(), static_cast<int>(line.size())) <= 0) {
            Fail("failed to send the USB tunnel handshake");
            SSL_free(ssl);
            ::close(localFd);
            ::close(remoteFd);
            localFd_.store(-1);
            remoteFd_.store(-1);
            return;
        }
    }
    {
        std::string buf;
        buf.reserve(128);
        char c;
        while (buf.size() < kMaxHandshakeBytes) {
            const int n = SSL_read(ssl, &c, 1);
            if (n <= 0) {
                Fail("tunnel closed during handshake");
                SSL_free(ssl);
                ::close(localFd);
                ::close(remoteFd);
                localFd_.store(-1);
                remoteFd_.store(-1);
                return;
            }
            if (c == '\n') break;
            buf += c;
        }
        // The only success reply is {"op":"ready"}; anything else carries a
        // reason. A substring scan is enough for this fixed contract.
        if (buf.find("\"op\":\"ready\"") == std::string::npos &&
            buf.find("\"op\": \"ready\"") == std::string::npos) {
            Fail("Sunshine refused: " + extractReason(buf));
            SSL_free(ssl);
            ::close(localFd);
            ::close(remoteFd);
            localFd_.store(-1);
            remoteFd_.store(-1);
            return;
        }
    }

    // Attach the reserved local connection and start pumping.
    {
        sockaddr_in localAddr{};
        localAddr.sin_family = AF_INET;
        localAddr.sin_addr.s_addr = inet_addr(config_.localHost.c_str());
        localAddr.sin_port = htons(config_.localPort);
        if (::connect(localFd, reinterpret_cast<sockaddr *>(&localAddr), sizeof(localAddr)) < 0) {
            Fail("local USB/IP server connect failed");
            SSL_free(ssl);
            ::close(localFd);
            ::close(remoteFd);
            localFd_.store(-1);
            remoteFd_.store(-1);
            return;
        }
    }

    // Handshake phase over: pump pacing is poll-driven from here on.
    tv.tv_sec = 0;
    setsockopt(remoteFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (onState_) onState_("ready", "");
    LOGI("[%{public}s] forwarding busid %{public}s", LOG_TAG, config_.localBusId.c_str());

    Pump(localFd, ssl);

    SSL_shutdown(ssl);
    SSL_free(ssl);
    ::close(localFd);
    ::close(remoteFd);
    localFd_.store(-1);
    remoteFd_.store(-1);
    if (!finished_.exchange(true) && onState_) {
        onState_("closed", "");
    }
}

void Tunnel::Pump(int localFd, void *sslPtr) {
    SSL *ssl = static_cast<SSL *>(sslPtr);
    const int remoteFd = SSL_get_fd(ssl);
    uint8_t buf[kIoBufferSize];

    while (running_.load() && !finished_.load()) {
        // SSL may have buffered a record beyond the last poll.
        if (SSL_pending(ssl) > 0) {
            const int n = SSL_read(ssl, buf, sizeof(buf));
            if (n <= 0) return;
            if (!WriteAllPlain(localFd, buf, static_cast<size_t>(n))) return;
            continue;
        }
        pollfd fds[2]{};
        fds[0].fd = localFd;
        fds[0].events = POLLIN;
        fds[1].fd = remoteFd;
        fds[1].events = POLLIN;
        const int rc = ::poll(fds, 2, 500);
        if (rc < 0) return;
        if (rc == 0) continue; // timeout: loop re-checks running_

        if (fds[0].revents & (POLLIN | POLLHUP)) {
            const ssize_t n = ::read(localFd, buf, sizeof(buf));
            if (n <= 0) return;
            size_t off = 0;
            while (off < static_cast<size_t>(n)) {
                const int written = SSL_write(ssl, buf + off, static_cast<int>(n - off));
                if (written <= 0) return;
                off += static_cast<size_t>(written);
            }
        }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            const int n = SSL_read(ssl, buf, sizeof(buf));
            if (n <= 0) return;
            if (!WriteAllPlain(localFd, buf, static_cast<size_t>(n))) return;
        }
    }
}

} // namespace usbip
