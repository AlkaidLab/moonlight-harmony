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

/**
 * Incrementally scans an HEVC Annex-B decode unit for HDR Vivid/CUVA SEI.
 * One scanner can consume multiple scatter-gather segments in order.
 */
class HdrVividMetadataScanner {
public:
    bool Scan(const uint8_t* data, size_t size);
    bool Finish();

private:
    static constexpr size_t kMaxSeiNalSize = 8192;

    void StartNal();
    void AppendNalByte(uint8_t value);
    bool FinishNal();
    static bool ContainsCuvaT35Payload(const uint8_t* nalData, size_t nalSize);

    std::array<uint8_t, kMaxSeiNalSize> seiNal_{};
    size_t seiNalSize_ = 0;
    size_t nalByteCount_ = 0;
    size_t pendingZeroCount_ = 0;
    bool inNal_ = false;
    bool captureNal_ = false;
    bool nalOverflow_ = false;
    bool detected_ = false;
};

#endif // HDR_VIVID_METADATA_SCANNER_H
