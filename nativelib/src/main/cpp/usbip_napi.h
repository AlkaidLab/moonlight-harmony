/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2025 Moonlight/AlkaidLab
 *
 * usbip_napi - NAPI surface for the USB/IP reverse tunnel.
 *
 * Exposes the usbip::Server (in-app USB/IP exporter over the USB DDK) and
 * usbip::Tunnel (TLS reverse tunnel to Sunshine) as one "UsbIp" object and
 * wires the tunnel's reserved loopback source port into the server's
 * listener authorization.
 */

#ifndef USBIP_NAPI_H
#define USBIP_NAPI_H

#include <napi/native_api.h>

namespace usbip {

void UsbIpNapi_Init(napi_env env, napi_value exports);

} // namespace usbip

#endif // USBIP_NAPI_H
