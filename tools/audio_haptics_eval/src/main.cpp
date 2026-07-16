// SPDX-License-Identifier: GPL-3.0-or-later
// P0 host evaluator. This file links the GPL aubio baseline and is not part of
// the future Apache-2.0 SDK.

#include "aubio_onset_wrapper.h"
#include "sdk_core_onset_wrapper.h"
#include "spectral_onset_detector.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr int kSchemaVersion = 1;

struct Options {
    fs::path input;
    fs::path labels;
    fs::path eventsOut;
    fs::path summaryOut;
    std::string backend = "all";
    int hopSize = 240;
    int runs = 30;
    int warmupRuns = 3;
    double matchWindowMs = 50.0;
};

struct WavData {
    uint32_t sampleRate = 0;
    uint16_t channels = 0;
    std::vector<int16_t> samples;

    size_t FrameCount() const {
        return channels == 0 ? 0 : samples.size() / channels;
    }

    double DurationSeconds() const {
        return sampleRate == 0 ? 0.0 : static_cast<double>(FrameCount()) / sampleRate;
    }
};

struct Label {
    double timeMs = 0.0;
    std::string eventType;
    double importance = 1.0;
};

struct Event {
    std::string backend;
    uint64_t outputSample = 0;
    double outputMs = 0.0;
    float descriptor = 0.0f;
    float thresholdedDescriptor = 0.0f;
};

struct Metrics {
    size_t truePositive = 0;
    size_t falsePositive = 0;
    size_t falseNegative = 0;
    double precision = 0.0;
    double recall = 0.0;
    double f1 = 0.0;
    double medianAbsErrorMs = 0.0;
    double p95AbsErrorMs = 0.0;
    double meanSignedErrorMs = 0.0;
};

struct Benchmark {
    size_t processCalls = 0;
    double callP50Us = 0.0;
    double callP95Us = 0.0;
    double callP99Us = 0.0;
    double callMaxUs = 0.0;
    double runMedianMs = 0.0;
    double realtimeFactor = 0.0;
};

struct BackendResult {
    std::string name;
    std::vector<Event> events;
    Metrics metrics;
    Benchmark benchmark;
};

uint16_t ReadLe16(std::istream& in) {
    uint8_t bytes[2]{};
    in.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
    if (!in) throw std::runtime_error("Unexpected EOF while reading uint16");
    return static_cast<uint16_t>(bytes[0]) |
           static_cast<uint16_t>(static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t ReadLe32(std::istream& in) {
    uint8_t bytes[4]{};
    in.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
    if (!in) throw std::runtime_error("Unexpected EOF while reading uint32");
    return static_cast<uint32_t>(bytes[0]) |
           (static_cast<uint32_t>(bytes[1]) << 8) |
           (static_cast<uint32_t>(bytes[2]) << 16) |
           (static_cast<uint32_t>(bytes[3]) << 24);
}

std::string ReadFourCc(std::istream& in) {
    char chars[4]{};
    in.read(chars, sizeof(chars));
    if (!in) throw std::runtime_error("Unexpected EOF while reading FourCC");
    return std::string(chars, sizeof(chars));
}

WavData ReadPcm16Wav(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Cannot open WAV: " + path.string());

    if (ReadFourCc(in) != "RIFF") {
        throw std::runtime_error("Only little-endian RIFF WAV is supported");
    }
    (void)ReadLe32(in);
    if (ReadFourCc(in) != "WAVE") {
        throw std::runtime_error("Invalid WAVE header");
    }

    bool haveFmt = false;
    bool haveData = false;
    uint16_t formatTag = 0;
    uint16_t channels = 0;
    uint16_t bitsPerSample = 0;
    uint16_t blockAlign = 0;
    uint32_t sampleRate = 0;
    std::vector<uint8_t> pcmBytes;

    while (in && !(haveFmt && haveData)) {
        const std::string chunkId = ReadFourCc(in);
        const uint32_t chunkSize = ReadLe32(in);
        const std::streampos chunkStart = in.tellg();

        if (chunkId == "fmt ") {
            if (chunkSize < 16) throw std::runtime_error("Invalid fmt chunk");
            formatTag = ReadLe16(in);
            channels = ReadLe16(in);
            sampleRate = ReadLe32(in);
            (void)ReadLe32(in);
            blockAlign = ReadLe16(in);
            bitsPerSample = ReadLe16(in);
            haveFmt = true;
        } else if (chunkId == "data") {
            pcmBytes.resize(chunkSize);
            if (chunkSize > 0) {
                in.read(reinterpret_cast<char*>(pcmBytes.data()), chunkSize);
                if (!in) throw std::runtime_error("Truncated data chunk");
            }
            haveData = true;
        }

        const std::streamoff paddedSize = static_cast<std::streamoff>(chunkSize + (chunkSize & 1u));
        in.clear();
        in.seekg(chunkStart + paddedSize);
    }

    if (!haveFmt || !haveData) throw std::runtime_error("WAV is missing fmt or data chunk");
    if (formatTag != 1 || bitsPerSample != 16) {
        throw std::runtime_error("Only PCM signed 16-bit WAV is supported");
    }
    if (channels == 0 || channels > 8 || sampleRate == 0) {
        throw std::runtime_error("Unsupported WAV channel count or sample rate");
    }
    if (blockAlign != channels * sizeof(int16_t) || pcmBytes.size() % blockAlign != 0) {
        throw std::runtime_error("Invalid PCM block alignment");
    }

    WavData wav;
    wav.sampleRate = sampleRate;
    wav.channels = channels;
    wav.samples.resize(pcmBytes.size() / 2);
    for (size_t i = 0; i < wav.samples.size(); ++i) {
        const uint16_t value = static_cast<uint16_t>(pcmBytes[i * 2]) |
                               static_cast<uint16_t>(static_cast<uint16_t>(pcmBytes[i * 2 + 1]) << 8);
        wav.samples[i] = static_cast<int16_t>(value);
    }
    return wav;
}

std::string Trim(std::string text) {
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    const auto last = text.find_last_not_of(" \t\r\n");
    return text.substr(first, last - first + 1);
}

std::vector<std::string> SplitCsvLine(const std::string& line) {
    std::vector<std::string> fields;
    std::string current;
    bool quoted = false;
    for (size_t i = 0; i < line.size(); ++i) {
        const char c = line[i];
        if (c == '"') {
            if (quoted && i + 1 < line.size() && line[i + 1] == '"') {
                current.push_back('"');
                ++i;
            } else {
                quoted = !quoted;
            }
        } else if (c == ',' && !quoted) {
            fields.push_back(Trim(current));
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    fields.push_back(Trim(current));
    return fields;
}

std::vector<Label> ReadLabels(const fs::path& path) {
    if (path.empty()) return {};
    std::ifstream in(path);
    if (!in) throw std::runtime_error("Cannot open labels: " + path.string());

    std::vector<Label> labels;
    std::string line;
    bool firstDataLine = true;
    while (std::getline(in, line)) {
        line = Trim(line);
        if (line.empty() || line[0] == '#') continue;
        const auto fields = SplitCsvLine(line);
        if (fields.empty()) continue;
        if (firstDataLine && fields[0] == "time_ms") {
            firstDataLine = false;
            continue;
        }
        firstDataLine = false;
        Label label;
        label.timeMs = std::stod(fields[0]);
        label.eventType = fields.size() > 1 ? fields[1] : "onset";
        label.importance = fields.size() > 2 ? std::stod(fields[2]) : 1.0;
        labels.push_back(std::move(label));
    }
    std::sort(labels.begin(), labels.end(), [](const Label& a, const Label& b) {
        return a.timeMs < b.timeMs;
    });
    return labels;
}

double Percentile(std::vector<double> values, double percentile) {
    if (values.empty()) return 0.0;
    std::sort(values.begin(), values.end());
    const double index = percentile * static_cast<double>(values.size() - 1);
    const size_t lower = static_cast<size_t>(std::floor(index));
    const size_t upper = static_cast<size_t>(std::ceil(index));
    if (lower == upper) return values[lower];
    const double fraction = index - static_cast<double>(lower);
    return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

Metrics ScoreEvents(const std::vector<Event>& events,
                    const std::vector<Label>& labels,
                    double matchWindowMs) {
    Metrics metrics;
    std::vector<bool> eventUsed(events.size(), false);
    std::vector<double> signedErrors;
    std::vector<double> absErrors;

    for (const Label& label : labels) {
        size_t bestIndex = events.size();
        double bestAbsError = std::numeric_limits<double>::max();
        double bestSignedError = 0.0;
        for (size_t i = 0; i < events.size(); ++i) {
            if (eventUsed[i]) continue;
            const double signedError = events[i].outputMs - label.timeMs;
            const double absError = std::abs(signedError);
            if (absError <= matchWindowMs && absError < bestAbsError) {
                bestIndex = i;
                bestAbsError = absError;
                bestSignedError = signedError;
            }
        }
        if (bestIndex != events.size()) {
            eventUsed[bestIndex] = true;
            ++metrics.truePositive;
            signedErrors.push_back(bestSignedError);
            absErrors.push_back(bestAbsError);
        } else {
            ++metrics.falseNegative;
        }
    }

    metrics.falsePositive = static_cast<size_t>(
        std::count(eventUsed.begin(), eventUsed.end(), false));
    const size_t predictedPositive = metrics.truePositive + metrics.falsePositive;
    const size_t actualPositive = metrics.truePositive + metrics.falseNegative;
    metrics.precision = predictedPositive == 0
        ? (actualPositive == 0 ? 1.0 : 0.0)
        : static_cast<double>(metrics.truePositive) / predictedPositive;
    metrics.recall = actualPositive == 0
        ? 1.0
        : static_cast<double>(metrics.truePositive) / actualPositive;
    metrics.f1 = (metrics.precision + metrics.recall) == 0.0
        ? 0.0
        : 2.0 * metrics.precision * metrics.recall / (metrics.precision + metrics.recall);
    metrics.medianAbsErrorMs = Percentile(absErrors, 0.50);
    metrics.p95AbsErrorMs = Percentile(absErrors, 0.95);
    metrics.meanSignedErrorMs = signedErrors.empty()
        ? 0.0
        : std::accumulate(signedErrors.begin(), signedErrors.end(), 0.0) /
              static_cast<double>(signedErrors.size());
    return metrics;
}

template <typename Detector>
std::vector<Event> CollectEvents(const std::string& backend,
                                 const WavData& wav,
                                 int hopSize) {
    Detector detector;
    if (!detector.Init(static_cast<int>(wav.sampleRate), hopSize, "specflux")) {
        throw std::runtime_error("Failed to initialize " + backend + " detector");
    }

    std::vector<Event> events;
    const size_t totalFrames = wav.FrameCount();
    for (size_t offset = 0; offset < totalFrames; offset += static_cast<size_t>(hopSize)) {
        const int count = static_cast<int>(
            std::min(static_cast<size_t>(hopSize), totalFrames - offset));
        bool detected = false;
        if (!detector.ProcessFrame(wav.samples.data() + offset * wav.channels,
                                   count,
                                   wav.channels,
                                   detected)) {
            throw std::runtime_error("Detector rejected PCM input");
        }
        if (detected) {
            const uint64_t outputSample = static_cast<uint64_t>(offset + count);
            events.push_back(Event{
                backend,
                outputSample,
                1000.0 * static_cast<double>(outputSample) / wav.sampleRate,
                detector.GetDescriptor(),
                detector.GetThresholdedDescriptor(),
            });
        }
    }
    return events;
}

template <typename Detector>
Benchmark RunBenchmark(const WavData& wav, int hopSize, int warmupRuns, int runs) {
    const size_t totalFrames = wav.FrameCount();
    volatile size_t detectionSink = 0;

    auto runOnce = [&](bool collectCallTimes, std::vector<double>& callTimesUs) {
        Detector detector;
        if (!detector.Init(static_cast<int>(wav.sampleRate), hopSize, "specflux")) {
            throw std::runtime_error("Failed to initialize detector for benchmark");
        }
        const auto runStart = std::chrono::steady_clock::now();
        for (size_t offset = 0; offset < totalFrames; offset += static_cast<size_t>(hopSize)) {
            const int count = static_cast<int>(
                std::min(static_cast<size_t>(hopSize), totalFrames - offset));
            bool detected = false;
            const auto callStart = std::chrono::steady_clock::now();
            detector.ProcessFrame(wav.samples.data() + offset * wav.channels,
                                  count,
                                  wav.channels,
                                  detected);
            const auto callEnd = std::chrono::steady_clock::now();
            detectionSink += detected ? 1u : 0u;
            if (collectCallTimes) {
                callTimesUs.push_back(
                    std::chrono::duration<double, std::micro>(callEnd - callStart).count());
            }
        }
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - runStart).count();
    };

    std::vector<double> unused;
    for (int i = 0; i < warmupRuns; ++i) {
        (void)runOnce(false, unused);
    }

    std::vector<double> runTimesMs;
    std::vector<double> callTimesUs;
    runTimesMs.reserve(static_cast<size_t>(runs));
    callTimesUs.reserve(static_cast<size_t>(runs) *
                        (totalFrames / static_cast<size_t>(hopSize) + 1));
    for (int i = 0; i < runs; ++i) {
        runTimesMs.push_back(runOnce(true, callTimesUs));
    }

    Benchmark benchmark;
    benchmark.processCalls = callTimesUs.size();
    benchmark.callP50Us = Percentile(callTimesUs, 0.50);
    benchmark.callP95Us = Percentile(callTimesUs, 0.95);
    benchmark.callP99Us = Percentile(callTimesUs, 0.99);
    benchmark.callMaxUs = callTimesUs.empty()
        ? 0.0
        : *std::max_element(callTimesUs.begin(), callTimesUs.end());
    benchmark.runMedianMs = Percentile(runTimesMs, 0.50);
    benchmark.realtimeFactor = benchmark.runMedianMs <= 0.0
        ? 0.0
        : wav.DurationSeconds() / (benchmark.runMedianMs / 1000.0);

    if (detectionSink == std::numeric_limits<size_t>::max()) {
        std::cerr << "unreachable sink=" << detectionSink << '\n';
    }
    return benchmark;
}

std::string JsonEscape(const std::string& value) {
    std::ostringstream out;
    for (const unsigned char c : value) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\b': out << "\\b"; break;
            case '\f': out << "\\f"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                        << static_cast<int>(c) << std::dec;
                } else {
                    out << static_cast<char>(c);
                }
        }
    }
    return out.str();
}

void EnsureParentDirectory(const fs::path& path) {
    if (!path.empty() && path.has_parent_path()) {
        fs::create_directories(path.parent_path());
    }
}

void WriteEventsCsv(const fs::path& path, const std::vector<BackendResult>& results) {
    EnsureParentDirectory(path);
    std::ofstream out(path);
    if (!out) throw std::runtime_error("Cannot write events CSV: " + path.string());
    out << "schema_version,backend,output_sample,output_ms,descriptor,thresholded_descriptor\n";
    out << std::fixed << std::setprecision(6);
    for (const auto& result : results) {
        for (const auto& event : result.events) {
            out << kSchemaVersion << ',' << event.backend << ',' << event.outputSample << ','
                << event.outputMs << ',' << event.descriptor << ','
                << event.thresholdedDescriptor << '\n';
        }
    }
}

void WriteSummaryJson(const fs::path& path,
                      const Options& options,
                      const WavData& wav,
                      size_t labelCount,
                      const std::vector<BackendResult>& results) {
    EnsureParentDirectory(path);
    std::ofstream out(path);
    if (!out) throw std::runtime_error("Cannot write summary JSON: " + path.string());
    out << std::fixed << std::setprecision(6);
    out << "{\n";
    out << "  \"schema_version\": " << kSchemaVersion << ",\n";
    out << "  \"sdk_version\": \"" << ah_get_version_string() << "\",\n";
    out << "  \"parameter_set_version\": \""
        << ah_get_parameter_set_version() << "\",\n";
    out << "  \"input\": {\n";
    out << "    \"path\": \"" << JsonEscape(fs::absolute(options.input).string()) << "\",\n";
    out << "    \"sample_rate\": " << wav.sampleRate << ",\n";
    out << "    \"channels\": " << wav.channels << ",\n";
    out << "    \"frame_count\": " << wav.FrameCount() << ",\n";
    out << "    \"duration_seconds\": " << wav.DurationSeconds() << "\n";
    out << "  },\n";
    out << "  \"config\": {\n";
    out << "    \"hop_size\": " << options.hopSize << ",\n";
    out << "    \"runs\": " << options.runs << ",\n";
    out << "    \"warmup_runs\": " << options.warmupRuns << ",\n";
    out << "    \"match_window_ms\": " << options.matchWindowMs << ",\n";
    out << "    \"timestamp_semantics\": \"detector output at hop end\"\n";
    out << "  },\n";
    out << "  \"label_count\": " << labelCount << ",\n";
    out << "  \"backends\": [\n";
    for (size_t i = 0; i < results.size(); ++i) {
        const BackendResult& result = results[i];
        const Metrics& m = result.metrics;
        const Benchmark& b = result.benchmark;
        out << "    {\n";
        out << "      \"name\": \"" << JsonEscape(result.name) << "\",\n";
        out << "      \"event_count\": " << result.events.size() << ",\n";
        out << "      \"metrics\": {\n";
        out << "        \"true_positive\": " << m.truePositive << ",\n";
        out << "        \"false_positive\": " << m.falsePositive << ",\n";
        out << "        \"false_negative\": " << m.falseNegative << ",\n";
        out << "        \"precision\": " << m.precision << ",\n";
        out << "        \"recall\": " << m.recall << ",\n";
        out << "        \"f1\": " << m.f1 << ",\n";
        out << "        \"median_abs_error_ms\": " << m.medianAbsErrorMs << ",\n";
        out << "        \"p95_abs_error_ms\": " << m.p95AbsErrorMs << ",\n";
        out << "        \"mean_signed_error_ms\": " << m.meanSignedErrorMs << "\n";
        out << "      },\n";
        out << "      \"benchmark\": {\n";
        out << "        \"process_calls\": " << b.processCalls << ",\n";
        out << "        \"call_p50_us\": " << b.callP50Us << ",\n";
        out << "        \"call_p95_us\": " << b.callP95Us << ",\n";
        out << "        \"call_p99_us\": " << b.callP99Us << ",\n";
        out << "        \"call_max_us\": " << b.callMaxUs << ",\n";
        out << "        \"run_median_ms\": " << b.runMedianMs << ",\n";
        out << "        \"realtime_factor\": " << b.realtimeFactor << "\n";
        out << "      }\n";
        out << "    }" << (i + 1 == results.size() ? "\n" : ",\n");
    }
    out << "  ]\n";
    out << "}\n";
}

void PrintUsage(std::ostream& out) {
    out << "Usage: audio_haptics_eval --input file.wav [options]\n"
        << "Options:\n"
        << "  --labels file.csv          Ground truth: time_ms,event_type,importance\n"
        << "  --backend aubio|native|sdk|both|all (default: all)\n"
        << "  --events-out file.csv      Event-level output\n"
        << "  --summary-out file.json    Metrics and benchmark summary\n"
        << "  --hop-size N               Analysis hop (default: 240)\n"
        << "  --runs N                   Timed benchmark runs (default: 30)\n"
        << "  --warmup-runs N            Untimed warmup runs (default: 3)\n"
        << "  --match-window-ms N        Label matching tolerance (default: 50)\n";
}

Options ParseOptions(int argc, char** argv) {
    Options options;
    auto requireValue = [&](int& index, std::string_view name) -> std::string {
        if (index + 1 >= argc) throw std::runtime_error("Missing value for " + std::string(name));
        return argv[++index];
    };

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            PrintUsage(std::cout);
            std::exit(0);
        } else if (arg == "--input") {
            options.input = requireValue(i, arg);
        } else if (arg == "--labels") {
            options.labels = requireValue(i, arg);
        } else if (arg == "--backend") {
            options.backend = requireValue(i, arg);
        } else if (arg == "--events-out") {
            options.eventsOut = requireValue(i, arg);
        } else if (arg == "--summary-out") {
            options.summaryOut = requireValue(i, arg);
        } else if (arg == "--hop-size") {
            options.hopSize = std::stoi(requireValue(i, arg));
        } else if (arg == "--runs") {
            options.runs = std::stoi(requireValue(i, arg));
        } else if (arg == "--warmup-runs") {
            options.warmupRuns = std::stoi(requireValue(i, arg));
        } else if (arg == "--match-window-ms") {
            options.matchWindowMs = std::stod(requireValue(i, arg));
        } else {
            throw std::runtime_error("Unknown argument: " + arg);
        }
    }

    if (options.input.empty()) throw std::runtime_error("--input is required");
    if (options.backend != "aubio" && options.backend != "native" &&
        options.backend != "sdk" && options.backend != "both" &&
        options.backend != "all") {
        throw std::runtime_error("--backend must be aubio, native, sdk, both, or all");
    }
    if (options.hopSize <= 0 || options.hopSize > 512) {
        throw std::runtime_error("--hop-size must be in 1..512");
    }
    if (options.runs <= 0 || options.warmupRuns < 0) {
        throw std::runtime_error("--runs must be positive and --warmup-runs non-negative");
    }
    if (options.matchWindowMs <= 0.0) {
        throw std::runtime_error("--match-window-ms must be positive");
    }

    if (options.eventsOut.empty()) {
        options.eventsOut = options.input;
        options.eventsOut.replace_extension(".events.csv");
    }
    if (options.summaryOut.empty()) {
        options.summaryOut = options.input;
        options.summaryOut.replace_extension(".summary.json");
    }
    return options;
}

template <typename Detector>
BackendResult EvaluateBackend(const std::string& name,
                              const WavData& wav,
                              const std::vector<Label>& labels,
                              const Options& options) {
    BackendResult result;
    result.name = name;
    result.events = CollectEvents<Detector>(name, wav, options.hopSize);
    result.metrics = ScoreEvents(result.events, labels, options.matchWindowMs);
    result.benchmark = RunBenchmark<Detector>(
        wav, options.hopSize, options.warmupRuns, options.runs);
    return result;
}

void PrintResult(const BackendResult& result) {
    std::cout << std::fixed << std::setprecision(3)
              << result.name
              << ": events=" << result.events.size()
              << " F1=" << result.metrics.f1
              << " timing_p50_ms=" << result.metrics.medianAbsErrorMs
              << " call_p99_us=" << result.benchmark.callP99Us
              << " realtime_x=" << result.benchmark.realtimeFactor
              << '\n';
}

} // namespace

int main(int argc, char** argv) {
    try {
        const Options options = ParseOptions(argc, argv);
        const WavData wav = ReadPcm16Wav(options.input);
        const std::vector<Label> labels = ReadLabels(options.labels);

        std::vector<BackendResult> results;
        if (options.backend == "aubio" || options.backend == "both" ||
            options.backend == "all") {
            results.push_back(EvaluateBackend<AubioOnsetWrapper>(
                "aubio", wav, labels, options));
        }
        if (options.backend == "native" || options.backend == "both" ||
            options.backend == "all") {
            results.push_back(EvaluateBackend<SpectralOnsetDetector>(
                "native_current", wav, labels, options));
        }
        if (options.backend == "sdk" || options.backend == "all") {
            results.push_back(EvaluateBackend<SdkCoreOnsetWrapper>(
                "sdk_core", wav, labels, options));
        }

        WriteEventsCsv(options.eventsOut, results);
        WriteSummaryJson(options.summaryOut, options, wav, labels.size(), results);

        std::cout << "input=" << fs::absolute(options.input).string()
                  << " duration_s=" << std::fixed << std::setprecision(3)
                  << wav.DurationSeconds()
                  << " sample_rate=" << wav.sampleRate
                  << " channels=" << wav.channels
                  << " labels=" << labels.size() << '\n';
        for (const auto& result : results) PrintResult(result);
        std::cout << "events=" << fs::absolute(options.eventsOut).string() << '\n'
                  << "summary=" << fs::absolute(options.summaryOut).string() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "audio_haptics_eval: " << error.what() << '\n';
        return 1;
    }
}
