// SPDX-License-Identifier: GPL-3.0-or-later

#include "moonlight_haptics/audio_haptics.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <string>
#include <time.h>
#include <vector>

namespace {

constexpr uint32_t kSampleRate = 48000U;
constexpr uint32_t kChannels = 2U;
constexpr uint32_t kBlockFrames = 240U;
constexpr uint32_t kPatternSeconds = 2U;
constexpr uint32_t kWarmupBlocks = 400U;
constexpr double kPi = 3.14159265358979323846;

struct Scenario {
    const char* name;
    std::vector<int16_t> pcm;
};

struct Result {
    const char* name = "";
    uint64_t blocks = 0U;
    uint64_t frames = 0U;
    uint64_t outputFrames = 0U;
    uint64_t transientFrames = 0U;
    uint64_t errors = 0U;
    double wallSeconds = 0.0;
    double cpuSeconds = 0.0;
    double p50Us = 0.0;
    double p95Us = 0.0;
    double p99Us = 0.0;
    double maximumUs = 0.0;
    double meanUs = 0.0;
    double realtimeFactor = 0.0;
};

int16_t ToPcm16(double value) {
    const double clamped = std::max(-1.0, std::min(1.0, value));
    return static_cast<int16_t>(std::lround(clamped * 32767.0));
}

uint32_t NextRandom(uint32_t& state) {
    state ^= state << 13U;
    state ^= state >> 17U;
    state ^= state << 5U;
    return state;
}

std::vector<int16_t> RenderPattern(const std::string& name) {
    const uint32_t frames = kSampleRate * kPatternSeconds;
    std::vector<int16_t> pcm(static_cast<size_t>(frames) * kChannels, 0);
    uint32_t randomState = 0x29aU;
    for (uint32_t frame = 0U; frame < frames; ++frame) {
        const double time = static_cast<double>(frame) / kSampleRate;
        double left = 0.0;
        double right = 0.0;
        if (name == "continuous_low_frequency") {
            left = right = 0.24 * std::sin(2.0 * kPi * 60.0 * time);
        } else if (name == "game_strong_transient") {
            const uint32_t phase = frame % (kSampleRate / 2U);
            if (phase < 720U) {
                const double envelope = std::exp(-static_cast<double>(phase) / 150.0);
                const double noise = static_cast<double>(NextRandom(randomState) & 0xffffU) / 32767.5 - 1.0;
                left = 0.88 * envelope * noise;
                right = -left;
            }
        } else if (name == "music_mix") {
            const double beatPhase = std::fmod(time, 0.5);
            const double beat = 0.30 * std::exp(-beatPhase * 18.0) * std::sin(2.0 * kPi * 70.0 * time);
            left = beat + 0.10 * std::sin(2.0 * kPi * 440.0 * time);
            right = beat + 0.10 * std::sin(2.0 * kPi * 554.37 * time);
        } else if (name == "speech_modulated") {
            const double envelope = 0.5 + 0.5 * std::sin(2.0 * kPi * 3.7 * time);
            left = right = 0.20 * envelope * (
                std::sin(2.0 * kPi * 180.0 * time) +
                0.35 * std::sin(2.0 * kPi * 360.0 * time));
        }
        const size_t index = static_cast<size_t>(frame) * kChannels;
        pcm[index] = ToPcm16(left);
        pcm[index + 1U] = ToPcm16(right);
    }
    return pcm;
}

double ProcessCpuSeconds() {
    timespec value{};
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) return 0.0;
    return static_cast<double>(value.tv_sec) + static_cast<double>(value.tv_nsec) / 1.0e9;
}

double Percentile(const std::vector<uint64_t>& sortedNs, double percentile) {
    if (sortedNs.empty()) return 0.0;
    const double rank = std::ceil(percentile * static_cast<double>(sortedNs.size()));
    const size_t index = static_cast<size_t>(std::max(1.0, rank) - 1.0);
    return static_cast<double>(sortedNs[index]) / 1000.0;
}

Result RunScenario(const Scenario& scenario, uint32_t durationSeconds) {
    AhConfig config{};
    if (ah_config_init(&config, kSampleRate, kChannels) != AH_STATUS_OK) {
        return Result{scenario.name, 0U, 0U, 0U, 0U, 1U};
    }
    config.requested_scene = AH_SCENE_GAME;
    AhEngine* engine = nullptr;
    if (ah_create(&config, &engine) != AH_STATUS_OK || engine == nullptr) {
        return Result{scenario.name, 0U, 0U, 0U, 0U, 1U};
    }

    const uint32_t capacity = ah_get_max_output_frames(engine, kBlockFrames);
    std::vector<AhHapticFrame> outputs(std::max(1U, capacity));
    const uint32_t patternBlocks = kSampleRate * kPatternSeconds / kBlockFrames;
    uint64_t sampleFrame = 0U;

    auto processOne = [&](uint64_t blockIndex, bool record, Result& result,
                          std::vector<uint64_t>& latencies) {
        const uint32_t patternBlock = static_cast<uint32_t>(blockIndex % patternBlocks);
        AhProcessInput input{};
        input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
        input.interleaved_pcm = scenario.pcm.data() +
            static_cast<size_t>(patternBlock) * kBlockFrames * kChannels;
        input.frame_count = kBlockFrames;
        input.first_sample_time_us = sampleFrame * 1000000ULL / kSampleRate;
        uint32_t outputCount = 0U;
        const auto start = std::chrono::steady_clock::now();
        const AhStatus status = ah_process_i16(
            engine, &input, outputs.data(), static_cast<uint32_t>(outputs.size()), &outputCount);
        const auto stop = std::chrono::steady_clock::now();
        sampleFrame += kBlockFrames;
        if (!record) {
            if (status != AH_STATUS_OK && status != AH_STATUS_OUTPUT_AVAILABLE) ++result.errors;
            return;
        }
        latencies.push_back(static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(stop - start).count()));
        ++result.blocks;
        result.frames += kBlockFrames;
        if (status != AH_STATUS_OK && status != AH_STATUS_OUTPUT_AVAILABLE) {
            ++result.errors;
            return;
        }
        result.outputFrames += outputCount;
        for (uint32_t index = 0U; index < outputCount; ++index) {
            if ((outputs[index].flags & AH_FRAME_TRANSIENT) != 0U) ++result.transientFrames;
        }
    };

    Result result{};
    result.name = scenario.name;
    std::vector<uint64_t> latencies;
    latencies.reserve(static_cast<size_t>(durationSeconds) * 20000U);
    for (uint64_t block = 0U; block < kWarmupBlocks; ++block) {
        processOne(block, false, result, latencies);
    }
    ah_reset(engine);
    sampleFrame = 0U;

    const auto wallStart = std::chrono::steady_clock::now();
    const double cpuStart = ProcessCpuSeconds();
    const auto deadline = wallStart + std::chrono::seconds(durationSeconds);
    uint64_t blockIndex = 0U;
    while (std::chrono::steady_clock::now() < deadline) {
        processOne(blockIndex++, true, result, latencies);
    }
    const double cpuStop = ProcessCpuSeconds();
    const auto wallStop = std::chrono::steady_clock::now();
    ah_destroy(engine);

    result.wallSeconds = std::chrono::duration<double>(wallStop - wallStart).count();
    result.cpuSeconds = std::max(0.0, cpuStop - cpuStart);
    const uint64_t totalNs = std::accumulate(latencies.begin(), latencies.end(), uint64_t{0U});
    result.meanUs = latencies.empty() ? 0.0 :
        static_cast<double>(totalNs) / static_cast<double>(latencies.size()) / 1000.0;
    std::sort(latencies.begin(), latencies.end());
    result.p50Us = Percentile(latencies, 0.50);
    result.p95Us = Percentile(latencies, 0.95);
    result.p99Us = Percentile(latencies, 0.99);
    result.maximumUs = latencies.empty() ? 0.0 : static_cast<double>(latencies.back()) / 1000.0;
    const double audioSeconds = static_cast<double>(result.frames) / kSampleRate;
    result.realtimeFactor = result.wallSeconds > 0.0 ? audioSeconds / result.wallSeconds : 0.0;
    return result;
}

uint32_t ParseDuration(int argc, char** argv) {
    uint32_t duration = 5U;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--duration-seconds" && index + 1 < argc) {
            const long parsed = std::strtol(argv[++index], nullptr, 10);
            if (parsed < 1L || parsed > 3600L) return 0U;
            duration = static_cast<uint32_t>(parsed);
        } else {
            return 0U;
        }
    }
    return duration;
}

void PrintResult(const std::vector<Result>& results, uint32_t durationSeconds) {
    std::cout << std::fixed << std::setprecision(3);
    std::cout << "{\n"
              << "  \"schema_version\": 1,\n"
              << "  \"sdk_version\": \"" << ah_get_version_string() << "\",\n"
              << "  \"abi_version\": " << ah_get_abi_version() << ",\n"
              << "  \"parameter_set_version\": \"" << ah_get_parameter_set_version() << "\",\n"
              << "  \"sample_rate_hz\": " << kSampleRate << ",\n"
              << "  \"channel_count\": " << kChannels << ",\n"
              << "  \"block_frames\": " << kBlockFrames << ",\n"
              << "  \"duration_seconds_per_scenario\": " << durationSeconds << ",\n"
              << "  \"synthetic_workload\": true,\n"
              << "  \"scenarios\": [\n";
    for (size_t index = 0U; index < results.size(); ++index) {
        const Result& result = results[index];
        std::cout << "    {\"name\": \"" << result.name
                  << "\", \"blocks\": " << result.blocks
                  << ", \"frames\": " << result.frames
                  << ", \"output_frames\": " << result.outputFrames
                  << ", \"transient_frames\": " << result.transientFrames
                  << ", \"errors\": " << result.errors
                  << ", \"wall_seconds\": " << result.wallSeconds
                  << ", \"cpu_seconds\": " << result.cpuSeconds
                  << ", \"mean_us\": " << result.meanUs
                  << ", \"p50_us\": " << result.p50Us
                  << ", \"p95_us\": " << result.p95Us
                  << ", \"p99_us\": " << result.p99Us
                  << ", \"max_us\": " << result.maximumUs
                  << ", \"realtime_factor\": " << result.realtimeFactor << "}";
        std::cout << (index + 1U == results.size() ? "\n" : ",\n");
    }
    std::cout << "  ]\n}\n";
}

} // namespace

int main(int argc, char** argv) {
    const uint32_t durationSeconds = ParseDuration(argc, argv);
    if (durationSeconds == 0U) {
        std::cerr << "usage: audio_haptics_android_bench [--duration-seconds 1..3600]\n";
        return 2;
    }
    const std::array<const char*, 5U> names = {
        "silence_noise_floor",
        "continuous_low_frequency",
        "game_strong_transient",
        "music_mix",
        "speech_modulated",
    };
    std::vector<Scenario> scenarios;
    scenarios.reserve(names.size());
    for (const char* name : names) scenarios.push_back(Scenario{name, RenderPattern(name)});

    std::vector<Result> results;
    results.reserve(scenarios.size());
    for (const Scenario& scenario : scenarios) {
        results.push_back(RunScenario(scenario, durationSeconds));
    }
    PrintResult(results, durationSeconds);
    return std::any_of(results.begin(), results.end(),
                       [](const Result& result) { return result.errors != 0U; }) ? 1 : 0;
}
