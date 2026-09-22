#pragma once
#include <cstddef>
#include <cstdint>
// Minimal compile-time DDK test doubles. These never cross the device ABI;
// production builds must use the HarmonyOS SDK headers instead.
struct UsbDeviceDescriptor {
    uint16_t idVendor, idProduct, bcdDevice;
    uint8_t bDeviceClass, bDeviceSubClass, bDeviceProtocol, bNumConfigurations;
};
struct UsbControlRequestSetup {
    uint8_t bmRequestType, bRequest;
    uint16_t wValue, wIndex, wLength;
};
struct UsbEndpointDescriptor {
    uint8_t bEndpointAddress, bmAttributes;
    uint16_t wMaxPacketSize;
    uint8_t bInterval;
};
struct UsbDdkEndpointDescriptor { UsbEndpointDescriptor endpointDescriptor; };
struct UsbInterfaceDescriptor {
    uint8_t bInterfaceNumber, bAlternateSetting, bInterfaceClass;
    uint8_t bInterfaceSubClass, bInterfaceProtocol, bNumEndpoints;
};
struct UsbDdkInterfaceDescriptor {
    UsbInterfaceDescriptor interfaceDescriptor;
    UsbDdkEndpointDescriptor *endPoint;
};
struct UsbDdkInterface {
    uint32_t numAltsetting;
    UsbDdkInterfaceDescriptor *altsetting;
};
struct UsbDdkConfigDescriptor {
    struct { uint8_t bNumInterfaces; } configDescriptor;
    UsbDdkInterface *interface;
};
struct UsbRequestPipe {
    uint64_t interfaceHandle;
    uint32_t timeout;
    uint8_t endpoint;
};
struct UsbDeviceMemMap {
    uint8_t *address;
    size_t size;
    uint32_t offset, bufferLength, transferedLength;
};
