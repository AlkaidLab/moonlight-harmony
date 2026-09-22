# USB/IP server protocol regression test

Run on Linux or WSL from the repository root:

```sh
g++ -std=c++17 -pthread \
  -Inativelib/src/test/cpp/usbip_stubs -Inativelib/src/main/cpp \
  nativelib/src/test/cpp/usbip_server_test.cpp \
  nativelib/src/main/cpp/usbip_server.cpp -ldl \
  -o /tmp/moonlight-usbip-server-test
/tmp/moonlight-usbip-server-test
```

The test connects to the real server through an authorized loopback socket,
imports a mock USB device, sends USB/IP URBs, and verifies replies. Only the
HarmonyOS DDK and logging dependencies are replaced; production transport and
request handling run unchanged. The test-only headers are not an SDK ABI check.

Coverage:

- GET_DESCRIPTOR with the original little-endian USB setup packet, returning
  an 18-byte device descriptor.
- HID SET_REPORT with nonzero wValue and wIndex, checking interface routing
  and the OUT payload.
- Interrupt IN endpoint number 4 converted to address 0x84 and routed to its
  owning interface (which differs from the first interface).
- Interrupt OUT endpoint 3 retained as address 0x03.

Before the fix, the first three cases fail with USB/IP statuses -75, -5, -5.
After the fix all four pass. This validates protocol handling, not real DDK
access, Windows enumeration, or controller haptics; those require device tests.

Protocol references:

- https://docs.kernel.org/usb/usbip_protocol.html (setup is raw USB data;
  endpoint number and direction are separate fields).
- https://github.com/torvalds/linux/blob/master/include/uapi/linux/usb/ch9.h
  (`usb_ctrlrequest` uses little-endian wValue, wIndex and wLength).
