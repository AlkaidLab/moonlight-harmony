// SPDX-License-Identifier: Apache-2.0

#ifndef MOONLIGHT_HAPTICS_CORE_CAUSAL_RHYTHM_CLOCK_H
#define MOONLIGHT_HAPTICS_CORE_CAUSAL_RHYTHM_CLOCK_H

#include <array>
#include <cstddef>
#include <cstdint>

namespace moonlight::haptics::core {

struct RhythmClockFrame {
    bool locked = false;
    bool coasting = false;
    bool reinforceBeat = false;
    bool onsetOnBeat = false;
    float tempoBpm = 0.0F;
    float candidateTempoBpm = 0.0F;
    float phase = 0.0F;
    float confidence = 0.0F;
    float activation = 0.0F;
};

/*
 * Fixed-capacity, zero-lookahead rhythm clock inspired by Real-Time PLP.
 *
 * A bank of causal complex resonators estimates the predominant local pulse
 * over 60..180 BPM. A fixed-capacity multi-hypothesis posterior combines the
 * dense activation field with phase-coherent evidence events. An established
 * clock can coast without producing haptics and rapidly wake after two aligned
 * events. Unlike the Python research implementation, this mobile
 * implementation performs no allocation, FFT, or matrix work on the audio
 * thread. Predictions are exposed only when the clock is actively locked and
 * a weak current acoustic transient supports the predicted pulse.
 */
class CausalRhythmClock {
public:
    CausalRhythmClock(uint32_t sampleRate, uint32_t hopSize);

    // Deterministic activation entry point used by host tests and benchmarks.
    RhythmClockFrame ProcessActivation(float activation,
                                       bool audible,
                                       bool acousticOnset,
                                       bool evidenceEvent) noexcept;

    void Reset() noexcept;

private:
    void ResetPulseState() noexcept;
    void EvaluateTempo() noexcept;
    float CurrentPhase() const noexcept;
    float CorrelationPhase(std::size_t tempoIndex) const noexcept;
    void AdvanceOscillators() noexcept;

    static constexpr uint32_t kMinimumBpm = 60U;
    static constexpr uint32_t kMaximumBpm = 180U;
    static constexpr std::size_t kTempoCount =
        static_cast<std::size_t>(kMaximumBpm - kMinimumBpm + 1U);
    static constexpr std::size_t kHypothesisCount = 8U;

    struct TempoHypothesis {
        std::size_t tempoIndex = 0U;
        float score = 0.0F;
    };

    uint32_t sampleRate_ = 0;
    uint32_t hopSize_ = 0;
    uint32_t evaluationIntervalHops_ = 0;
    uint32_t evidenceSeparationHops_ = 0;
    uint32_t acousticOnsetSuppressionHops_ = 0;
    uint32_t coastingEvidenceTimeoutHops_ = 0;
    uint32_t eventFreshnessHops_ = 0;
    uint32_t silenceUnlockHops_ = 0;
    float correlationDecay_ = 0.0F;
    float eventCorrelationDecay_ = 0.0F;

    std::array<float, kTempoCount> oscillatorReal_{};
    std::array<float, kTempoCount> oscillatorImaginary_{};
    std::array<float, kTempoCount> rotationReal_{};
    std::array<float, kTempoCount> rotationImaginary_{};
    std::array<float, kTempoCount> correlationReal_{};
    std::array<float, kTempoCount> correlationImaginary_{};
    std::array<float, kTempoCount> eventCorrelationReal_{};
    std::array<float, kTempoCount> eventCorrelationImaginary_{};
    std::array<float, kTempoCount> hypothesisPosterior_{};
    std::array<TempoHypothesis, kHypothesisCount> hypotheses_{};

    std::size_t selectedTempoIndex_ = 0;
    std::size_t candidateTempoIndex_ = 0;
    std::size_t challengerTempoIndex_ = 0;
    uint32_t hopsSeen_ = 0;
    uint32_t hopsSinceEvaluation_ = 0;
    uint32_t hopsSinceEvidence_ = 0;
    uint32_t hopsSinceEvidenceEvent_ = 0;
    uint32_t hopsSinceAcousticOnset_ = 0;
    uint32_t evidenceEventCount_ = 0;
    uint32_t candidateStableEvaluations_ = 0;
    uint32_t challengerEvaluations_ = 0;
    uint32_t lowConfidenceEvaluations_ = 0;
    uint32_t coastingEvaluations_ = 0;
    uint32_t coastingAlignedEvents_ = 0;
    uint32_t beatEvidenceWindowHops_ = 0;
    uint32_t phaseSettlingHops_ = 0;
    float activationMass_ = 0.0F;
    float eventActivationMass_ = 0.0F;
    float previousActivation_ = 0.0F;
    float previousPhase_ = 0.0F;
    float trackedPhase_ = 0.0F;
    float confidence_ = 0.0F;
    bool locked_ = false;
    bool coasting_ = false;
    bool candidateValid_ = false;
    bool phaseInitialized_ = false;
    bool trackedPhaseInitialized_ = false;
    bool reinforcedThisCycle_ = false;
};

} // namespace moonlight::haptics::core

#endif // MOONLIGHT_HAPTICS_CORE_CAUSAL_RHYTHM_CLOCK_H
