#include "hdr_vivid_metadata_scanner.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

void Expect(bool condition, const char* description) {
    if (condition) {
        return;
    }
    std::cerr << "FAILED: " << description << '\n';
    std::exit(EXIT_FAILURE);
}

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
    Expect(ScanSegments(segments), "detect CUVA across scatter segments");
}

void TestDetectsCuvaSuffixSei() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x00, 0x01, 0x50, 0x01,
        0x04, 0x05, 0x26, 0x00, 0x04, 0x00, 0x05, 0x80,
    }};
    Expect(ScanSegments(segments), "detect CUVA suffix SEI");
}

void TestIgnoresHevcWithoutSei() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x26, 0x01, 0xAA, 0xBB, 0xCC,
    }};
    Expect(!ScanSegments(segments), "ignore HEVC without SEI");
}

void TestIgnoresHdr10PlusT35() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x4E, 0x01,
        0x04, 0x05, 0xB5, 0x00, 0x3C, 0x00, 0x01, 0x80,
    }};
    Expect(!ScanSegments(segments), "ignore HDR10+ T.35 metadata");
}

void TestRemovesEmulationPreventionBytes() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x4E, 0x01,
        0x05, 0x03, 0x00, 0x00, 0x03, 0x01,
        0x04, 0x05, 0x26, 0x00, 0x04, 0x00, 0x05, 0x80,
    }};
    Expect(ScanSegments(segments), "remove emulation prevention bytes");
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
