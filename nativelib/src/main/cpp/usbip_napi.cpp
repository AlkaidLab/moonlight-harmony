/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * usbip_napi.cpp - NAPI glue for the USB/IP server + reverse tunnel.
 */

#include "usbip_napi.h"

#include <cstring>
#include <memory>
#include <mutex>
#include <string>

#include <hilog/log.h>
#include <napi/native_api.h>

#include "usbip_server.h"
#include "usbip_tunnel.h"

#define LOG_TAG "UsbIpNapi"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)

namespace usbip {

namespace {

enum class TunnelState : int {
    kIdle = 0,
    kConnecting = 1,
    kReady = 2,
    kClosed = 3,
    kError = 4,
};

const char *tunnelStateName(TunnelState s) {
    switch (s) {
        case TunnelState::kIdle: return "idle";
        case TunnelState::kConnecting: return "connecting";
        case TunnelState::kReady: return "ready";
        case TunnelState::kClosed: return "closed";
        case TunnelState::kError: return "error";
    }
    return "idle";
}

std::mutex g_mutex;
std::shared_ptr<DdkApi> g_ddk;
std::unique_ptr<Server> g_server;
std::unique_ptr<Tunnel> g_tunnel;
napi_threadsafe_function g_tunnelTsfn = nullptr;
// Written from the tunnel thread, read from JS threads querying status.
// Guarded by its own lock: g_mutex may be held while joining the tunnel
// thread (Stop*), so taking it from the callback would deadlock.
std::mutex g_stateMutex;
TunnelState g_tunnelState = TunnelState::kIdle;
std::string g_tunnelMessage;

struct TunnelEvent {
    char state[16];
    char *message; // malloc'd; ownership passes to the JS callback
};

void tunnelEventOnJs(napi_env env, napi_value jsCallback, void * /*context*/, void *rawData) {
    auto *event = static_cast<TunnelEvent *>(rawData);
    if (env != nullptr && jsCallback != nullptr) {
        napi_value stateVal, msgVal, undefined;
        napi_create_string_utf8(env, event->state, NAPI_AUTO_LENGTH, &stateVal);
        napi_create_string_utf8(env, event->message ? event->message : "", NAPI_AUTO_LENGTH, &msgVal);
        napi_get_undefined(env, &undefined);
        napi_value argv[2] = { stateVal, msgVal };
        napi_call_function(env, undefined, jsCallback, 2, argv, nullptr);
    }
    if (event->message) free(event->message);
    delete event;
}

void setFieldInt(napi_env env, napi_value obj, const char *name, int64_t v) {
    napi_value val;
    napi_create_int64(env, v, &val);
    napi_set_named_property(env, obj, name, val);
}

void setFieldStr(napi_env env, napi_value obj, const char *name, const char *v) {
    napi_value val;
    napi_create_string_utf8(env, v ? v : "", NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, obj, name, val);
}

std::string getStringArg(napi_env env, napi_value value) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok || len > 64 * 1024) {
        return {};
    }
    std::string out(len, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, value, out.data(), out.size() + 1, &copied);
    out.resize(copied);
    return out;
}

// ============================================================
// Server
// ============================================================

napi_value StartServer(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_server && g_server->IsRunning()) {
        setFieldInt(env, result, "code", 0);
        setFieldInt(env, result, "port", g_server->BoundPort());
        return result;
    }
    if (g_ddk == nullptr) {
        g_ddk = LoadDdk();
        if (g_ddk == nullptr) {
            setFieldInt(env, result, "code", -1);
            setFieldStr(env, result, "error", "USB DDK 不可用");
            return result;
        }
    }
    g_server = std::make_unique<Server>(g_ddk);
    std::string error;
    const int port = g_server->Start(&error);
    if (port < 0) {
        g_server.reset();
        setFieldInt(env, result, "code", -1);
        setFieldStr(env, result, "error", error.c_str());
        return result;
    }
    setFieldInt(env, result, "code", 0);
    setFieldInt(env, result, "port", port);
    return result;
}

napi_value StopServer(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_tunnel) {
        g_tunnel->Stop();
        g_tunnel.reset();
    }
    if (g_tunnelTsfn != nullptr) {
        napi_release_threadsafe_function(g_tunnelTsfn, napi_tsfn_release);
        g_tunnelTsfn = nullptr;
    }
    {
        std::lock_guard<std::mutex> stateLock(g_stateMutex);
        g_tunnelState = TunnelState::kIdle;
        g_tunnelMessage.clear();
    }
    if (g_server) {
        g_server->Stop();
        g_server.reset();
    }
    setFieldInt(env, result, "code", 0);
    return result;
}

napi_value AddDevice(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    napi_create_object(env, &result);
    setFieldInt(env, result, "code", -1);

    int32_t busNum = 0, devAddr = 0;
    std::string name;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &busNum);
        napi_get_value_int32(env, args[1], &devAddr);
    }
    if (argc >= 3) {
        name = getStringArg(env, args[2]);
    }
    if (busNum <= 0 || devAddr <= 0) {
        setFieldStr(env, result, "error", "invalid busNum/devAddress");
        return result;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_server || !g_server->IsRunning()) {
        setFieldStr(env, result, "error", "server not running");
        return result;
    }
    std::string error;
    if (!g_server->AddDevice(static_cast<uint32_t>(busNum), static_cast<uint32_t>(devAddr),
                             name, &error)) {
        setFieldStr(env, result, "error", error.c_str());
        return result;
    }
    const std::vector<DeviceInfo> list = g_server->devices();
    for (const auto &dev : list) {
        if (dev.busNum == static_cast<uint32_t>(busNum) &&
            dev.devAddress == static_cast<uint32_t>(devAddr)) {
            setFieldInt(env, result, "code", 0);
            setFieldStr(env, result, "busId", dev.busId.c_str());
            setFieldInt(env, result, "vendorId", dev.vendorId);
            setFieldInt(env, result, "productId", dev.productId);
            setFieldInt(env, result, "interfaces", static_cast<int64_t>(dev.interfaces.size()));
            setFieldInt(env, result, "hasIsochronous", dev.hasIsochronous ? 1 : 0);
            break;
        }
    }
    return result;
}

napi_value RemoveDevice(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    napi_create_object(env, &result);
    if (argc < 1) {
        setFieldInt(env, result, "code", -1);
        return result;
    }
    const std::string busId = getStringArg(env, args[0]);
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_server) {
        g_server->RemoveDevice(busId);
    }
    setFieldInt(env, result, "code", 0);
    return result;
}

// ============================================================
// Tunnel
// ============================================================

napi_value StartTunnel(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    napi_create_object(env, &result);
    setFieldInt(env, result, "code", -1);
    if (argc < 2 || args[0] == nullptr) {
        setFieldStr(env, result, "error", "invalid arguments");
        return result;
    }

    TunnelConfig config;
    {
        napi_value v;
        if (napi_get_named_property(env, args[0], "host", &v) == napi_ok) config.host = getStringArg(env, v);
        if (napi_get_named_property(env, args[0], "token", &v) == napi_ok) config.sessionToken = getStringArg(env, v);
        if (napi_get_named_property(env, args[0], "busId", &v) == napi_ok) config.localBusId = getStringArg(env, v);
        if (napi_get_named_property(env, args[0], "clientCertPem", &v) == napi_ok) config.clientCertPem = getStringArg(env, v);
        if (napi_get_named_property(env, args[0], "clientKeyPem", &v) == napi_ok) config.clientKeyPem = getStringArg(env, v);
        if (napi_get_named_property(env, args[0], "serverCertPem", &v) == napi_ok) config.serverCertPem = getStringArg(env, v);
        int32_t port = 0;
        if (napi_get_named_property(env, args[0], "port", &v) == napi_ok) {
            napi_get_value_int32(env, v, &port);
            if (port > 0) config.port = static_cast<uint16_t>(port);
        }
    }

    std::lock_guard<std::mutex> lock(g_mutex);

    if (!g_server || !g_server->IsRunning()) {
        setFieldStr(env, result, "error", "USB/IP server not running");
        return result;
    }
    if (g_tunnel) {
        setFieldStr(env, result, "error", "tunnel already running");
        return result;
    }
    config.localPort = static_cast<uint16_t>(g_server->BoundPort());
    const bool valid = !config.host.empty() && config.port != 0 &&
                       !config.sessionToken.empty() && !config.clientCertPem.empty() &&
                       !config.clientKeyPem.empty() && !config.serverCertPem.empty() &&
                       !config.localBusId.empty() && config.localPort != 0;
    if (!valid) {
        setFieldStr(env, result, "error", "tunnel configuration incomplete");
        return result;
    }

    // JS state callback (threadsafe; the tunnel reports from its own thread).
    if (g_tunnelTsfn != nullptr) {
        napi_release_threadsafe_function(g_tunnelTsfn, napi_tsfn_release);
        g_tunnelTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "UsbIpTunnelState", NAPI_AUTO_LENGTH, &resName);
    if (napi_create_threadsafe_function(env, args[1], nullptr, resName, 16, 1,
                                        nullptr, nullptr, nullptr,
                                        tunnelEventOnJs, &g_tunnelTsfn) != napi_ok) {
        g_tunnelTsfn = nullptr;
        setFieldStr(env, result, "error", "failed to create state callback");
        return result;
    }

    Server *server = g_server.get();
    config.onLocalBound = [server](uint16_t port) { server->AuthorizePort(port); };

    {
        std::lock_guard<std::mutex> stateLock(g_stateMutex);
        g_tunnelState = TunnelState::kConnecting;
        g_tunnelMessage.clear();
    }
    g_tunnel = std::make_unique<Tunnel>(std::move(config));
    g_tunnel->Start([](const char *state, const char *message) {
        // Runs on the tunnel thread: update the pollable snapshot and
        // forward to JS.
        std::string messageCopy = message ? message : "";
        {
            std::lock_guard<std::mutex> stateLock(g_stateMutex);
            if (strcmp(state, "connecting") == 0) g_tunnelState = TunnelState::kConnecting;
            else if (strcmp(state, "ready") == 0) g_tunnelState = TunnelState::kReady;
            else if (strcmp(state, "closed") == 0) g_tunnelState = TunnelState::kClosed;
            else g_tunnelState = TunnelState::kError;
            g_tunnelMessage = messageCopy;
        }

        auto *event = new (std::nothrow) TunnelEvent{};
        if (event == nullptr) return;
        strncpy(event->state, state, sizeof(event->state) - 1);
        event->message = static_cast<char *>(malloc(messageCopy.size() + 1));
        if (event->message != nullptr) {
            memcpy(event->message, messageCopy.c_str(), messageCopy.size() + 1);
        }
        // On queue-full/closing the call fails and ownership of the data
        // stays with us.
        if (g_tunnelTsfn == nullptr ||
            napi_call_threadsafe_function(g_tunnelTsfn, event, napi_tsfn_nonblocking) != napi_ok) {
            if (event->message) free(event->message);
            delete event;
        }
    });

    setFieldInt(env, result, "code", 0);
    return result;
}

napi_value StopTunnel(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_tunnel) {
        g_tunnel->Stop(); // joins the tunnel thread, which may report state
        g_tunnel.reset();
    }
    if (g_tunnelTsfn != nullptr) {
        napi_release_threadsafe_function(g_tunnelTsfn, napi_tsfn_release);
        g_tunnelTsfn = nullptr;
    }
    {
        std::lock_guard<std::mutex> stateLock(g_stateMutex);
        g_tunnelState = TunnelState::kIdle;
        g_tunnelMessage.clear();
    }
    setFieldInt(env, result, "code", 0);
    return result;
}

napi_value TunnelStateQuery(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);
    std::lock_guard<std::mutex> stateLock(g_stateMutex);
    setFieldStr(env, result, "state", tunnelStateName(g_tunnelState));
    setFieldStr(env, result, "message", g_tunnelMessage.c_str());
    return result;
}

} // namespace

void UsbIpNapi_Init(napi_env env, napi_value exports) {
    napi_value obj;
    napi_create_object(env, &obj);

    napi_property_descriptor methods[] = {
        { "startServer", nullptr, StartServer, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopServer", nullptr, StopServer, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "addDevice", nullptr, AddDevice, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "removeDevice", nullptr, RemoveDevice, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startTunnel", nullptr, StartTunnel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopTunnel", nullptr, StopTunnel, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "tunnelState", nullptr, TunnelStateQuery, nullptr, nullptr, nullptr, napi_default, nullptr },
    };

    napi_define_properties(env, obj, sizeof(methods) / sizeof(methods[0]), methods);
    napi_set_named_property(env, exports, "UsbIp", obj);

    LOGI("[%{public}s] UsbIp NAPI registered", LOG_TAG);
}

} // namespace usbip
