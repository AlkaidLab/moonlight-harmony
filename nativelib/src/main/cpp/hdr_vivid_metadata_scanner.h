/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#ifndef HDR_VIVID_METADATA_SCANNER_H
#define HDR_VIVID_METADATA_SCANNER_H

#include <array>
#include <cstddef>
#include <cstdint>

enum class HdrVividBitstreamFormat {
    HEVC_ANNEX_B,
    AV1_LOW_OVERHEAD_OBU,
};

/**
 * Incrementally scans a decode unit for HDR Vivid/CUVA T.35 metadata.
 * One scanner can consume multiple scatter-gather segments in order.
 */
class HdrVividMetadataScanner {
public:
    explicit HdrVividMetadataScanner(
        HdrVividBitstreamFormat format = HdrVividBitstreamFormat::HEVC_ANNEX_B);

    bool Scan(const uint8_t* data, size_t size);
    bool Finish();

private:
    static constexpr size_t kMaxSeiNalSize = 8192;
    static constexpr size_t kMaxAv1MetadataPrefixSize = 32;

    enum class Av1ParseState {
        OBU_HEADER,
        OBU_EXTENSION,
        OBU_SIZE,
        OBU_PAYLOAD,
        INVALID,
    };

    bool ScanHevc(const uint8_t* data, size_t size);
    bool FinishHevc();
    void StartNal();
    void AppendNalByte(uint8_t value);
    bool FinishNal();
    static bool ContainsCuvaT35Payload(const uint8_t* nalData, size_t nalSize);

    bool ScanAv1(const uint8_t* data, size_t size);
    bool FinishAv1();
    void StartAv1Obu(uint8_t header);
    bool FinishAv1Obu();
    static bool ContainsCuvaAv1Metadata(
        const uint8_t* payload, size_t payloadSize);

    HdrVividBitstreamFormat format_;

    std::array<uint8_t, kMaxSeiNalSize> seiNal_{};
    size_t seiNalSize_ = 0;
    size_t nalByteCount_ = 0;
    size_t pendingZeroCount_ = 0;
    bool inNal_ = false;
    bool captureNal_ = false;
    bool nalOverflow_ = false;
    bool detected_ = false;

    Av1ParseState av1State_ = Av1ParseState::OBU_HEADER;
    std::array<uint8_t, kMaxAv1MetadataPrefixSize> av1MetadataPrefix_{};
    size_t av1MetadataPrefixSize_ = 0;
    uint64_t av1ObuSize_ = 0;
    uint64_t av1PayloadBytesRead_ = 0;
    uint64_t av1LebValue_ = 0;
    uint8_t av1LebShift_ = 0;
    uint8_t av1LebBytes_ = 0;
    bool av1HasSizeField_ = false;
    bool av1CaptureMetadata_ = false;
};

#endif // HDR_VIVID_METADATA_SCANNER_H
