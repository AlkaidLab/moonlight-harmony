#include "hdr_vivid_metadata_scanner.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <utility>
#include <vector>

namespace {

void Expect(bool condition, const char* description) {
    if (condition) {
        return;
    }
    std::cerr << "FAILED: " << description << '\n';
    std::exit(EXIT_FAILURE);
}

bool ScanSegments(
        const std::vector<std::vector<uint8_t>>& segments,
        HdrVividBitstreamFormat format =
            HdrVividBitstreamFormat::HEVC_ANNEX_B) {
    HdrVividMetadataScanner scanner(format);
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

void TestDetectsCuvaAfterHdr10PlusInSameSeiNal() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x00, 0x01, 0x4E, 0x01,
        0x04, 0x05, 0xB5, 0x00, 0x3C, 0x00, 0x01,
        0x04, 0x06, 0x26, 0x00, 0x04, 0x00, 0x05, 0x01,
        0x80,
    }};
    Expect(ScanSegments(segments),
           "detect CUVA after HDR10+ in the same prefix SEI NAL");
}

void TestRemovesEmulationPreventionBytes() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x00, 0x00, 0x01, 0x4E, 0x01,
        0x05, 0x03, 0x00, 0x00, 0x03, 0x01,
        0x04, 0x05, 0x26, 0x00, 0x04, 0x00, 0x05, 0x80,
    }};
    Expect(ScanSegments(segments), "remove emulation prevention bytes");
}

void TestDetectsCuvaAv1MetadataObuAcrossScatterSegments() {
    const std::vector<std::vector<uint8_t>> segments = {
        // OBU_METADATA, obu_has_size_field=1, payload size=7.
        {0x2A},
        {0x07, 0x04, 0x26},
        {0x00, 0x04, 0x00},
        {0x05, 0x01},
    };
    Expect(ScanSegments(
               segments, HdrVividBitstreamFormat::AV1_LOW_OVERHEAD_OBU),
           "detect CUVA AV1 metadata OBU across scatter segments");
}

void TestDetectsCuvaAv1MetadataObuWithExtensionHeader() {
    const std::vector<std::vector<uint8_t>> segments = {{
        // Empty temporal delimiter OBU.
        0x12, 0x00,
        // OBU_METADATA with extension header and a valid CUVA T.35 payload.
        0x2E, 0x00, 0x07,
        0x04, 0x26, 0x00, 0x04, 0x00, 0x05, 0x01,
    }};
    Expect(ScanSegments(
               segments, HdrVividBitstreamFormat::AV1_LOW_OVERHEAD_OBU),
           "detect CUVA AV1 metadata OBU with extension header");
}

void TestDetectsCuvaAv1MetadataObuWithMultiByteSize() {
    std::vector<uint8_t> decodeUnit = {
        // OBU_METADATA with a 130-byte payload (LEB128 0x82 0x01).
        0x2A, 0x82, 0x01,
        0x04, 0x26, 0x00, 0x04, 0x00, 0x05, 0x01,
    };
    decodeUnit.resize(3 + 130, 0x00);
    const std::vector<std::vector<uint8_t>> segments = {
        std::move(decodeUnit),
    };
    Expect(ScanSegments(
               segments, HdrVividBitstreamFormat::AV1_LOW_OVERHEAD_OBU),
           "detect CUVA AV1 metadata OBU with multi-byte size");
}

void TestDetectsCuvaAv1MetadataObuWithoutSizeAtEnd() {
    const std::vector<std::vector<uint8_t>> segments = {{
        // A size-less OBU consumes the rest of this decode unit.
        0x28, 0x04, 0x26, 0x00, 0x04, 0x00, 0x05, 0x01,
    }};
    Expect(ScanSegments(
               segments, HdrVividBitstreamFormat::AV1_LOW_OVERHEAD_OBU),
           "detect CUVA AV1 metadata OBU without size at decode-unit end");
}

void TestIgnoresHdr10PlusAv1MetadataObu() {
    const std::vector<std::vector<uint8_t>> segments = {{
        0x2A, 0x07,
        0x04, 0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
    }};
    Expect(!ScanSegments(
               segments, HdrVividBitstreamFormat::AV1_LOW_OVERHEAD_OBU),
           "ignore HDR10+ AV1 metadata OBU");
}

} // namespace

int main() {
    TestDetectsCuvaAcrossScatterSegments();
    TestDetectsCuvaSuffixSei();
    TestIgnoresHevcWithoutSei();
    TestIgnoresHdr10PlusT35();
    TestDetectsCuvaAfterHdr10PlusInSameSeiNal();
    TestRemovesEmulationPreventionBytes();
    TestDetectsCuvaAv1MetadataObuAcrossScatterSegments();
    TestDetectsCuvaAv1MetadataObuWithExtensionHeader();
    TestDetectsCuvaAv1MetadataObuWithMultiByteSize();
    TestDetectsCuvaAv1MetadataObuWithoutSizeAtEnd();
    TestIgnoresHdr10PlusAv1MetadataObu();
    std::cout << "HDR Vivid metadata scanner tests passed\n";
    return 0;
}
