/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include "hdr_vivid_metadata_scanner.h"

#include <limits>

namespace {

constexpr uint8_t kHevcPrefixSeiNalType = 39;
constexpr uint8_t kHevcSuffixSeiNalType = 40;
constexpr uint32_t kRegisteredT35PayloadType = 4;

// CUVA 005.1 HDR Vivid identifier in user_data_registered_itu_t_t35.
constexpr uint8_t kCuvaCountryCode = 0x26;
constexpr uint16_t kCuvaTerminalProviderCode = 0x0004;
constexpr uint16_t kCuvaProviderOrientedCode = 0x0005;

class RbspByteReader {
public:
    RbspByteReader(const uint8_t* data, size_t size)
        : data_(data), size_(size) {}

    bool Read(uint8_t& value) {
        while (offset_ < size_) {
            const uint8_t current = data_[offset_++];
            if (!justSkippedPreventionByte_ && zeroCount_ >= 2 && current == 0x03) {
                justSkippedPreventionByte_ = true;
                continue;
            }

            justSkippedPreventionByte_ = false;
            value = current;
            if (current == 0x00) {
                zeroCount_++;
            } else {
                zeroCount_ = 0;
            }
            return true;
        }
        return false;
    }

private:
    const uint8_t* data_;
    size_t size_;
    size_t offset_ = 0;
    int zeroCount_ = 0;
    bool justSkippedPreventionByte_ = false;
};

bool ReadSeiValue(RbspByteReader& reader, uint32_t& value) {
    value = 0;
    uint8_t current = 0;
    do {
        if (!reader.Read(current) ||
            value > std::numeric_limits<uint32_t>::max() - current) {
            return false;
        }
        value += current;
    } while (current == 0xFF);
    return true;
}

} // namespace

bool HdrVividMetadataScanner::Scan(const uint8_t* data, size_t size) {
    if (detected_ || data == nullptr) {
        return detected_;
    }

    for (size_t index = 0; index < size; ++index) {
        const uint8_t current = data[index];
        if (!inNal_) {
            if (current == 0x00) {
                pendingZeroCount_++;
            } else if (current == 0x01 && pendingZeroCount_ >= 2) {
                StartNal();
            } else {
                pendingZeroCount_ = 0;
            }
            continue;
        }

        if (current == 0x00) {
            pendingZeroCount_++;
            continue;
        }

        if (current == 0x01 && pendingZeroCount_ >= 2) {
            if (FinishNal()) {
                detected_ = true;
                return true;
            }
            StartNal();
            continue;
        }

        while (pendingZeroCount_ > 0) {
            AppendNalByte(0x00);
            pendingZeroCount_--;
        }
        AppendNalByte(current);
    }

    return detected_;
}

bool HdrVividMetadataScanner::Finish() {
    if (!detected_ && inNal_ && FinishNal()) {
        detected_ = true;
    }
    inNal_ = false;
    pendingZeroCount_ = 0;
    return detected_;
}

void HdrVividMetadataScanner::StartNal() {
    inNal_ = true;
    pendingZeroCount_ = 0;
    seiNalSize_ = 0;
    nalByteCount_ = 0;
    captureNal_ = false;
    nalOverflow_ = false;
}

void HdrVividMetadataScanner::AppendNalByte(uint8_t value) {
    if (nalByteCount_ == 0) {
        const uint8_t nalType = static_cast<uint8_t>((value >> 1) & 0x3F);
        captureNal_ = nalType == kHevcPrefixSeiNalType ||
                      nalType == kHevcSuffixSeiNalType;
    }
    nalByteCount_++;

    if (!captureNal_ || nalOverflow_) {
        return;
    }
    if (seiNalSize_ >= seiNal_.size()) {
        nalOverflow_ = true;
        return;
    }
    seiNal_[seiNalSize_++] = value;
}

bool HdrVividMetadataScanner::FinishNal() {
    if (!captureNal_ || nalOverflow_) {
        return false;
    }
    return ContainsCuvaT35Payload(seiNal_.data(), seiNalSize_);
}

bool HdrVividMetadataScanner::ContainsCuvaT35Payload(
        const uint8_t* nalData, size_t nalSize) {
    if (nalSize <= 2) {
        return false;
    }

    RbspByteReader reader(nalData + 2, nalSize - 2);
    while (true) {
        uint32_t payloadType = 0;
        uint32_t payloadSize = 0;
        if (!ReadSeiValue(reader, payloadType) ||
            !ReadSeiValue(reader, payloadSize)) {
            return false;
        }

        bool isCuvaPayload = payloadType == kRegisteredT35PayloadType &&
                             payloadSize >= 5;
        uint8_t identifier[5] = {};
        for (uint32_t index = 0; index < payloadSize; ++index) {
            uint8_t value = 0;
            if (!reader.Read(value)) {
                return false;
            }
            if (index < sizeof(identifier)) {
                identifier[index] = value;
            }
        }

        if (isCuvaPayload) {
            const uint16_t terminalProviderCode =
                static_cast<uint16_t>(identifier[1] << 8) | identifier[2];
            const uint16_t providerOrientedCode =
                static_cast<uint16_t>(identifier[3] << 8) | identifier[4];
            if (identifier[0] == kCuvaCountryCode &&
                terminalProviderCode == kCuvaTerminalProviderCode &&
                providerOrientedCode == kCuvaProviderOrientedCode) {
                return true;
            }
        }
    }
}
