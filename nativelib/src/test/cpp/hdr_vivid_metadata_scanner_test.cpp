#include "hdr_vivid_metadata_scanner.h"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

bool ScanSegments(const std::vector<std::vector<uint8_t>>& segments) {
    HdrVividMetadataScanner scanner;
    for (const std::vector<uint8_t>& segment : segments) {
        if (scanner.Scan(segment.data(), segment.size())) {
            return true;
        }
    }
    return scanner.Finish();
}

void TestDetectsCuvaAcrossScatterSegments() {
    const std::vector<std::vector<uint8_t>> segments = {
        {0x00, 0x00},
        {0x01, 0x4E},
        {0x01, 0x04, 0x05, 0x26},
        {0x00, 0x04, 0x00, 0x05, 0x80},
    };
    assert(ScanSegments(segments));
}

void TestDetectsCuvaSuffixSei() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x00, 0x01, 0x50, 0x01,
        0x04, 0x05, 0x26, 0x00, 0x04, 0x00, 0x05, 0x80,
    }};
    assert(ScanSegments(segments));
}

void TestIgnoresHevcWithoutSei() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x26, 0x01, 0xAA, 0xBB, 0xCC,
    }};
    assert(!ScanSegments(segments));
}

void TestIgnoresHdr10PlusT35() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x4E, 0x01,
        0x04, 0x05, 0xB5, 0x00, 0x3C, 0x00, 0x01, 0x80,
    }};
    assert(!ScanSegments(segments));
}

void TestRemovesEmulationPreventionBytes() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x4E, 0x01,
        0x05, 0x03, 0x00, 0x00, 0x03, 0x01,
        0x04, 0x05, 0x26, 0x00, 0x04, 0x00, 0x05, 0x80,
    }};
    assert(ScanSegments(segments));
}

} // namespace

int main() {
    TestDetectsCuvaAcrossScatterSegments();
    TestDetectsCuvaSuffixSei();
    TestIgnoresHevcWithoutSei();
    TestIgnoresHdr10PlusT35();
    TestRemovesEmulationPreventionBytes();
    std::cout << "HDR Vivid metadata scanner tests passed\n";
    return 0;
}
