// SPDX-License-Identifier: Apache-2.0

#include "core/causal_rhythm_clock.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace moonlight::haptics::core {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr float kEvidenceThreshold = 0.20F;
constexpr float kPredictionEvidenceThreshold = 0.08F;
constexpr float kLockConfidence = 0.58F;
constexpr float kPredictionConfidence = 0.50F;
constexpr float kDoubleTempoSupportWeight = 0.80F;
constexpr float kHalfTempoSupportWeight = 0.20F;
constexpr float kCandidateSwitchRatio = 1.08F;
constexpr float kOctaveSwitchRatio = 1.12F;
constexpr float kLockedCandidateSwitchRatio = 1.20F;
constexpr float kLockedOctaveSwitchRatio = 1.20F;
constexpr uint32_t kCandidateLockStableEvaluations = 12U;
constexpr uint32_t kCandidateSwitchEvaluations = 8U;
constexpr uint32_t kOctaveSwitchEvaluations = 20U;
constexpr uint32_t kLockedCandidateSwitchEvaluations = 40U;
constexpr uint32_t kLockedOctaveSwitchEvaluations = 80U;
constexpr uint32_t kEnterCoastingLowConfidenceEvaluations = 32U;
constexpr uint32_t kMaximumCoastingEvaluations = 120U;
constexpr uint32_t kCoastingRecoveryEvents = 2U;
constexpr float kCoastingRecoveryConfidence = 0.36F;
constexpr float kStrongCoastingChallengerConfidence = 0.60F;
constexpr uint32_t kNearbyTempoToleranceBpm = 3U;
constexpr uint32_t kAcquisitionRefinementToleranceBpm = 6U;
constexpr uint32_t kOctaveToleranceBpm = 4U;

float Clamp01(float value) noexcept {
    return std::max(0.0F, std::min(1.0F, value));
}

uint32_t SecondsToHops(float seconds,
                       uint32_t sampleRate,
                       uint32_t hopSize) noexcept {
    return std::max(
        1U,
        static_cast<uint32_t>(std::ceil(
            static_cast<double>(seconds) * static_cast<double>(sampleRate) /
            static_cast<double>(hopSize))));
}

float TactusPrior(uint32_t bpm) noexcept {
    if (bpm < 72U) {
        return 0.88F + 0.12F *
            static_cast<float>(bpm - 60U) / 12.0F;
    }
    if (bpm > 150U) {
        return 1.0F - 0.15F *
            static_cast<float>(bpm - 150U) / 30.0F;
    }
    return 1.0F;
}

bool IsNearbyTempo(uint32_t lhs, uint32_t rhs) noexcept {
    const uint32_t distance = lhs > rhs ? lhs - rhs : rhs - lhs;
    return distance <= kNearbyTempoToleranceBpm;
}

bool IsOctaveRelated(uint32_t lhs, uint32_t rhs) noexcept {
    const uint32_t lower = std::min(lhs, rhs);
    const uint32_t higher = std::max(lhs, rhs);
    const uint32_t doubled = lower * 2U;
    const uint32_t distance = higher > doubled
        ? higher - doubled
        : doubled - higher;
    return distance <= kOctaveToleranceBpm;
}

float WrapPhase(float phase) noexcept {
    phase -= std::floor(phase);
    return phase < 0.0F ? phase + 1.0F : phase;
}

} // namespace

CausalRhythmClock::CausalRhythmClock(uint32_t sampleRate, uint32_t hopSize)
    : sampleRate_(sampleRate),
      hopSize_(hopSize),
      evaluationIntervalHops_(SecondsToHops(0.050F, sampleRate, hopSize)),
      evidenceSeparationHops_(SecondsToHops(0.060F, sampleRate, hopSize)),
      acousticOnsetSuppressionHops_(SecondsToHops(0.050F, sampleRate, hopSize)),
      coastingEvidenceTimeoutHops_(SecondsToHops(1.0F, sampleRate, hopSize)),
      eventFreshnessHops_(SecondsToHops(1.0F, sampleRate, hopSize)),
      silenceUnlockHops_(SecondsToHops(8.0F, sampleRate, hopSize)),
      correlationDecay_(static_cast<float>(std::exp(
          -static_cast<double>(hopSize) /
          (2.5 * static_cast<double>(sampleRate))))),
      eventCorrelationDecay_(static_cast<float>(std::exp(
          -static_cast<double>(hopSize) /
          (6.0 * static_cast<double>(sampleRate))))) {
    const double hopSeconds = static_cast<double>(hopSize_) /
                              static_cast<double>(sampleRate_);
    for (std::size_t index = 0; index < kTempoCount; ++index) {
        const double bpm = static_cast<double>(kMinimumBpm) +
                           static_cast<double>(index);
        const double radians = -2.0 * kPi * (bpm / 60.0) * hopSeconds;
        rotationReal_[index] = static_cast<float>(std::cos(radians));
        rotationImaginary_[index] = static_cast<float>(std::sin(radians));
    }
    Reset();
}

RhythmClockFrame CausalRhythmClock::ProcessActivation(
    float activation,
    bool audible,
    bool acousticOnset,
    bool evidenceEvent) noexcept {
    RhythmClockFrame output;
    activation = audible ? Clamp01(activation) : 0.0F;

    if (activation >= kPredictionEvidenceThreshold) {
        hopsSinceEvidence_ = 0U;
    } else if (hopsSinceEvidence_ < std::numeric_limits<uint32_t>::max()) {
        ++hopsSinceEvidence_;
    }
    bool acceptedEvidenceEvent = false;
    if (activation >= kEvidenceThreshold && evidenceEvent) {
        if (hopsSinceEvidenceEvent_ >= evidenceSeparationHops_) {
            evidenceEventCount_ = std::min(evidenceEventCount_ + 1U, 16U);
            hopsSinceEvidenceEvent_ = 0U;
            acceptedEvidenceEvent = true;
        }
    }
    if (hopsSinceEvidenceEvent_ < std::numeric_limits<uint32_t>::max()) {
        ++hopsSinceEvidenceEvent_;
    }

    if (acousticOnset) {
        hopsSinceAcousticOnset_ = 0U;
    } else if (hopsSinceAcousticOnset_ < std::numeric_limits<uint32_t>::max()) {
        ++hopsSinceAcousticOnset_;
    }

    activationMass_ = correlationDecay_ * activationMass_ + activation;
    eventActivationMass_ = eventCorrelationDecay_ * eventActivationMass_ +
        (acceptedEvidenceEvent ? activation : 0.0F);
    for (std::size_t index = 0; index < kTempoCount; ++index) {
        correlationReal_[index] =
            correlationDecay_ * correlationReal_[index] +
            activation * oscillatorReal_[index];
        correlationImaginary_[index] =
            correlationDecay_ * correlationImaginary_[index] +
            activation * oscillatorImaginary_[index];
        eventCorrelationReal_[index] =
            eventCorrelationDecay_ * eventCorrelationReal_[index] +
            (acceptedEvidenceEvent
                ? activation * oscillatorReal_[index]
                : 0.0F);
        eventCorrelationImaginary_[index] =
            eventCorrelationDecay_ * eventCorrelationImaginary_[index] +
            (acceptedEvidenceEvent
                ? activation * oscillatorImaginary_[index]
                : 0.0F);
    }

    ++hopsSeen_;
    ++hopsSinceEvaluation_;
    if (hopsSinceEvaluation_ >= evaluationIntervalHops_) {
        EvaluateTempo();
        hopsSinceEvaluation_ = 0U;
    }

    const float phase = CurrentPhase();
    const float phaseDistance = std::min(phase, 1.0F - phase);
    if (locked_ && trackedPhaseInitialized_ && acceptedEvidenceEvent &&
        phaseDistance <= 0.20F) {
        if (coasting_) {
            coastingAlignedEvents_ = std::min(
                coastingAlignedEvents_ + 1U,
                kCoastingRecoveryEvents);
        }
        const float signedError = phase <= 0.5F ? -phase : 1.0F - phase;
        trackedPhase_ = WrapPhase(
            trackedPhase_ + (coasting_ ? 0.25F : 0.12F) * signedError);
    }

    const bool activeLock = locked_ && !coasting_;
    bool crossedBeat = false;
    if (activeLock) {
        if (phaseInitialized_) {
            crossedBeat = previousPhase_ > 0.75F && phase < 0.25F;
        } else {
            phaseInitialized_ = true;
        }
        if (crossedBeat && phaseSettlingHops_ == 0U) {
            beatEvidenceWindowHops_ = 8U;
        }
    } else {
        phaseInitialized_ = false;
        beatEvidenceWindowHops_ = 0U;
        reinforcedThisCycle_ = false;
    }

    if (phaseSettlingHops_ > 0U) --phaseSettlingHops_;
    // A predicted pulse still needs a local acoustic rise. A sustained bed or
    // broadband fill can keep activation above the floor, but must not be
    // interpreted as a sequence of missing beats merely because the retained
    // phase crosses zero.
    const bool acousticSupport =
        activation >= kPredictionEvidenceThreshold &&
        activation >= previousActivation_ + 0.01F;
    if (phase > 0.25F && phase < 0.75F) reinforcedThisCycle_ = false;
    const bool insideBeatPhaseGate = phaseDistance <= 0.18F;
    output.reinforceBeat = activeLock && lowConfidenceEvaluations_ == 0U &&
        confidence_ >= kPredictionConfidence &&
        (beatEvidenceWindowHops_ > 0U || insideBeatPhaseGate) &&
        acousticSupport && !acousticOnset && !reinforcedThisCycle_ &&
        hopsSinceAcousticOnset_ > acousticOnsetSuppressionHops_;
    if (output.reinforceBeat) {
        beatEvidenceWindowHops_ = 0U;
        reinforcedThisCycle_ = true;
    } else if (beatEvidenceWindowHops_ > 0U) {
        --beatEvidenceWindowHops_;
    }

    output.onsetOnBeat = activeLock && lowConfidenceEvaluations_ == 0U &&
                         acousticOnset && confidence_ >= 0.50F &&
                         phaseDistance <= 0.18F;
    output.locked = activeLock;
    output.coasting = locked_ && coasting_;
    output.tempoBpm = activeLock
        ? static_cast<float>(kMinimumBpm + selectedTempoIndex_)
        : 0.0F;
    output.candidateTempoBpm = candidateValid_
        ? static_cast<float>(kMinimumBpm + candidateTempoIndex_)
        : 0.0F;
    output.phase = phase;
    // Expose acquisition confidence and the leading candidate before lock so
    // hosts can distinguish warm-up from a weak/aperiodic activation stream.
    output.confidence = Clamp01(confidence_);
    output.activation = activation;

    previousActivation_ = activation;
    previousPhase_ = phase;
    AdvanceOscillators();

    if (hopsSinceEvidence_ >= silenceUnlockHops_) {
        ResetPulseState();
    }
    return output;
}

void CausalRhythmClock::EvaluateTempo() noexcept {
    std::array<float, kTempoCount> rawScores{};
    if (activationMass_ > 1.0e-5F) {
        for (std::size_t index = 0; index < kTempoCount; ++index) {
            const float real = correlationReal_[index];
            const float imaginary = correlationImaginary_[index];
            rawScores[index] =
                std::sqrt(real * real + imaginary * imaginary) /
                activationMass_;
        }
    }

    std::array<float, kTempoCount> eventRawScores{};
    if (eventActivationMass_ > 1.0e-5F) {
        for (std::size_t index = 0; index < kTempoCount; ++index) {
            const float real = eventCorrelationReal_[index];
            const float imaginary = eventCorrelationImaginary_[index];
            eventRawScores[index] =
                std::sqrt(real * real + imaginary * imaginary) /
                eventActivationMass_;
        }
    }

    const float eventFreshness = Clamp01(
        1.0F - static_cast<float>(hopsSinceEvidenceEvent_) /
            static_cast<float>(eventFreshnessHops_));
    std::array<float, kTempoCount> combinedScores{};
    for (std::size_t index = 0; index < kTempoCount; ++index) {
        const uint32_t bpm = kMinimumBpm + static_cast<uint32_t>(index);
        float activationFamily = rawScores[index];
        float eventFamily = eventRawScores[index];
        if (bpm * 2U <= kMaximumBpm) {
            activationFamily += kDoubleTempoSupportWeight *
                rawScores[static_cast<std::size_t>(
                    bpm * 2U - kMinimumBpm)];
            eventFamily += kDoubleTempoSupportWeight *
                eventRawScores[static_cast<std::size_t>(
                    bpm * 2U - kMinimumBpm)];
        }
        const uint32_t halfBpm = (bpm + 1U) / 2U;
        if (halfBpm >= kMinimumBpm) {
            activationFamily += kHalfTempoSupportWeight *
                rawScores[static_cast<std::size_t>(
                    halfBpm - kMinimumBpm)];
            eventFamily += kHalfTempoSupportWeight *
                eventRawScores[static_cast<std::size_t>(
                    halfBpm - kMinimumBpm)];
        }
        const float prior = TactusPrior(bpm);
        activationFamily *= prior;
        eventFamily *= prior;

        // The activation resonator remains authoritative for dense rhythmic
        // beds. Sparse evidence events add a longer-horizon phase likelihood,
        // which survives missing onsets without granting stale events an
        // unlimited vote.
        const float combinedEvidence = std::max(
            activationFamily,
            0.35F * activationFamily +
                0.75F * eventFreshness * eventFamily);
        hypothesisPosterior_[index] =
            0.82F * hypothesisPosterior_[index] +
            0.18F * combinedEvidence;
        combinedScores[index] = hypothesisPosterior_[index];
    }

    // Extract eight distinct tempo modes rather than collapsing the complete
    // posterior to a single noisy maximum. Neighbouring BPM bins form one
    // hypothesis; half/double-time modes remain available for tactus logic.
    for (std::size_t slot = 0U; slot < kHypothesisCount; ++slot) {
        std::size_t slotBestIndex = 0U;
        float slotBestScore = -1.0F;
        for (std::size_t index = 0U; index < kTempoCount; ++index) {
            const uint32_t bpm = kMinimumBpm + static_cast<uint32_t>(index);
            bool overlapsExisting = false;
            for (std::size_t priorSlot = 0U; priorSlot < slot; ++priorSlot) {
                const uint32_t priorBpm = kMinimumBpm +
                    static_cast<uint32_t>(hypotheses_[priorSlot].tempoIndex);
                if (IsNearbyTempo(bpm, priorBpm)) {
                    overlapsExisting = true;
                    break;
                }
            }
            if (!overlapsExisting && combinedScores[index] > slotBestScore) {
                slotBestScore = combinedScores[index];
                slotBestIndex = index;
            }
        }
        hypotheses_[slot] = {slotBestIndex, std::max(0.0F, slotBestScore)};
    }

    std::size_t bestIndex = hypotheses_[0].tempoIndex;
    float bestScore = hypotheses_[0].score;

    const float eventReadiness = Clamp01(
        (static_cast<float>(evidenceEventCount_) - 2.0F) / 2.0F);
    const float establishedConfidence = locked_
        ? Clamp01(combinedScores[selectedTempoIndex_]) * eventReadiness
        : Clamp01(bestScore) * eventReadiness;

    if (!candidateValid_) {
        candidateTempoIndex_ = bestIndex;
        challengerTempoIndex_ = bestIndex;
        candidateStableEvaluations_ = 1U;
        challengerEvaluations_ = 0U;
        candidateValid_ = true;
    } else if (coasting_) {
        candidateTempoIndex_ = selectedTempoIndex_;
        if (candidateStableEvaluations_ <
            std::numeric_limits<uint32_t>::max()) {
            ++candidateStableEvaluations_;
        }

        const uint32_t selectedBpm =
            kMinimumBpm + static_cast<uint32_t>(selectedTempoIndex_);
        const uint32_t bestBpm =
            kMinimumBpm + static_cast<uint32_t>(bestIndex);
        const bool octaveRelated = IsOctaveRelated(selectedBpm, bestBpm);
        const float switchRatio = octaveRelated
            ? kLockedOctaveSwitchRatio
            : kLockedCandidateSwitchRatio;
        const uint32_t requiredEvaluations = octaveRelated
            ? kLockedOctaveSwitchEvaluations
            : kLockedCandidateSwitchEvaluations;
        const float selectedScore = combinedScores[selectedTempoIndex_];
        if (!IsNearbyTempo(selectedBpm, bestBpm) &&
            bestScore >= kStrongCoastingChallengerConfidence &&
            bestScore >= selectedScore * switchRatio) {
            const uint32_t challengerBpm =
                kMinimumBpm + static_cast<uint32_t>(challengerTempoIndex_);
            if (challengerEvaluations_ > 0U &&
                IsNearbyTempo(challengerBpm, bestBpm)) {
                ++challengerEvaluations_;
            } else {
                challengerTempoIndex_ = bestIndex;
                challengerEvaluations_ = 1U;
            }
            if (challengerEvaluations_ >= requiredEvaluations) {
                selectedTempoIndex_ = challengerTempoIndex_;
                candidateTempoIndex_ = selectedTempoIndex_;
                challengerEvaluations_ = 0U;
                coasting_ = false;
                coastingEvaluations_ = 0U;
                coastingAlignedEvents_ = 0U;
                lowConfidenceEvaluations_ = 0U;
                trackedPhase_ = CorrelationPhase(selectedTempoIndex_);
                trackedPhaseInitialized_ = true;
                phaseInitialized_ = false;
                reinforcedThisCycle_ = false;
                bestIndex = selectedTempoIndex_;
                bestScore = combinedScores[bestIndex];
            }
        } else {
            challengerEvaluations_ = 0U;
        }
    } else if (locked_ &&
               establishedConfidence < kPredictionConfidence &&
               bestScore < kStrongCoastingChallengerConfidence) {
        // Low-coherence sections may preserve the established clock, but they
        // must not promote a noisy challenger behind the scenes. Predictions
        // are already gated while lowConfidenceEvaluations_ is non-zero.
        candidateTempoIndex_ = selectedTempoIndex_;
        challengerTempoIndex_ = selectedTempoIndex_;
        challengerEvaluations_ = 0U;
        if (candidateStableEvaluations_ <
            std::numeric_limits<uint32_t>::max()) {
            ++candidateStableEvaluations_;
        }
    } else {
        const uint32_t candidateBpm =
            kMinimumBpm + static_cast<uint32_t>(candidateTempoIndex_);
        const uint32_t bestBpm =
            kMinimumBpm + static_cast<uint32_t>(bestIndex);
        const uint32_t candidateDistance = candidateBpm > bestBpm
            ? candidateBpm - bestBpm
            : bestBpm - candidateBpm;
        if (!locked_ &&
            candidateDistance <= kAcquisitionRefinementToleranceBpm) {
            candidateTempoIndex_ = bestIndex;
            challengerEvaluations_ = 0U;
            if (candidateStableEvaluations_ <
                std::numeric_limits<uint32_t>::max()) {
                ++candidateStableEvaluations_;
            }
        } else if (IsNearbyTempo(candidateBpm, bestBpm)) {
            challengerEvaluations_ = 0U;
            if (candidateStableEvaluations_ <
                std::numeric_limits<uint32_t>::max()) {
                ++candidateStableEvaluations_;
            }
        } else {
            const bool octaveRelated = IsOctaveRelated(candidateBpm, bestBpm);
            const float switchRatio = locked_
                ? (octaveRelated
                    ? kLockedOctaveSwitchRatio
                    : kLockedCandidateSwitchRatio)
                : (octaveRelated
                    ? kOctaveSwitchRatio
                    : kCandidateSwitchRatio);
            const uint32_t requiredEvaluations = locked_
                ? (octaveRelated
                    ? kLockedOctaveSwitchEvaluations
                    : kLockedCandidateSwitchEvaluations)
                : (octaveRelated
                    ? kOctaveSwitchEvaluations
                    : kCandidateSwitchEvaluations);
            const float candidateScore = combinedScores[candidateTempoIndex_];
            if (bestScore >= candidateScore * switchRatio) {
                candidateStableEvaluations_ = 0U;
                const uint32_t challengerBpm =
                    kMinimumBpm + static_cast<uint32_t>(challengerTempoIndex_);
                if (challengerEvaluations_ > 0U &&
                    IsNearbyTempo(challengerBpm, bestBpm)) {
                    ++challengerEvaluations_;
                } else {
                    challengerTempoIndex_ = bestIndex;
                    challengerEvaluations_ = 1U;
                }
                if (challengerEvaluations_ >= requiredEvaluations) {
                    candidateTempoIndex_ = challengerTempoIndex_;
                    candidateStableEvaluations_ = 1U;
                    challengerEvaluations_ = 0U;
                }
            } else {
                challengerEvaluations_ = 0U;
                if (candidateStableEvaluations_ <
                    std::numeric_limits<uint32_t>::max()) {
                    ++candidateStableEvaluations_;
                }
            }
        }
    }

    bestIndex = candidateTempoIndex_;
    bestScore = combinedScores[bestIndex];

    const float targetConfidence = Clamp01(bestScore) * eventReadiness;
    const float confidenceAlpha = locked_ && targetConfidence < confidence_
        ? 0.08F
        : 0.35F;
    confidence_ += confidenceAlpha * (targetConfidence - confidence_);

    if (!locked_) {
        if (evidenceEventCount_ >= 5U &&
            candidateStableEvaluations_ >= kCandidateLockStableEvaluations &&
            targetConfidence >= kLockConfidence) {
            selectedTempoIndex_ = bestIndex;
            locked_ = true;
            coasting_ = false;
            phaseInitialized_ = false;
            trackedPhase_ = CorrelationPhase(selectedTempoIndex_);
            trackedPhaseInitialized_ = true;
            reinforcedThisCycle_ = false;
            lowConfidenceEvaluations_ = 0U;
            coastingEvaluations_ = 0U;
            coastingAlignedEvents_ = 0U;
            confidence_ = targetConfidence;
        }
        return;
    }

    if (bestIndex != selectedTempoIndex_) {
        selectedTempoIndex_ = bestIndex;
        phaseInitialized_ = false;
        trackedPhase_ = CorrelationPhase(selectedTempoIndex_);
        trackedPhaseInitialized_ = true;
        reinforcedThisCycle_ = false;
        const float bpm = static_cast<float>(kMinimumBpm + selectedTempoIndex_);
        const float beatHops = 60.0F * static_cast<float>(sampleRate_) /
                               (bpm * static_cast<float>(hopSize_));
        phaseSettlingHops_ = static_cast<uint32_t>(
            std::max(1.0F, std::round(0.5F * beatHops)));
    }

    if (coasting_) {
        candidateTempoIndex_ = selectedTempoIndex_;
        if (coastingAlignedEvents_ >= kCoastingRecoveryEvents &&
            targetConfidence >= kCoastingRecoveryConfidence) {
            coasting_ = false;
            coastingEvaluations_ = 0U;
            coastingAlignedEvents_ = 0U;
            lowConfidenceEvaluations_ = 0U;
            confidence_ = std::max(kPredictionConfidence, targetConfidence);
            phaseInitialized_ = false;
            reinforcedThisCycle_ = false;
            return;
        }

        coastingEvaluations_ = std::min(
            coastingEvaluations_ + 1U,
            kMaximumCoastingEvaluations);
        if (coastingEvaluations_ >= kMaximumCoastingEvaluations) {
            locked_ = false;
            coasting_ = false;
            trackedPhaseInitialized_ = false;
            phaseInitialized_ = false;
            reinforcedThisCycle_ = false;
            candidateStableEvaluations_ = 0U;
            challengerEvaluations_ = 0U;
            lowConfidenceEvaluations_ = 0U;
            coastingAlignedEvents_ = 0U;
        }
        return;
    }

    if (targetConfidence < 0.30F) {
        lowConfidenceEvaluations_ = std::min(
            lowConfidenceEvaluations_ + 1U,
            kEnterCoastingLowConfidenceEvaluations);
    } else {
        lowConfidenceEvaluations_ = 0U;
    }

    if (lowConfidenceEvaluations_ >=
            kEnterCoastingLowConfidenceEvaluations ||
        hopsSinceEvidence_ >= coastingEvidenceTimeoutHops_) {
            coasting_ = true;
            candidateTempoIndex_ = selectedTempoIndex_;
            phaseInitialized_ = false;
            reinforcedThisCycle_ = false;
            lowConfidenceEvaluations_ = 0U;
            coastingEvaluations_ = 0U;
            coastingAlignedEvents_ = 0U;
            challengerEvaluations_ = 0U;
    }
}

float CausalRhythmClock::CurrentPhase() const noexcept {
    if (!locked_ || !trackedPhaseInitialized_) return 0.0F;
    return trackedPhase_;
}

float CausalRhythmClock::CorrelationPhase(std::size_t index) const noexcept {
    const float correlationReal = correlationReal_[index];
    const float correlationImaginary = correlationImaginary_[index];
    const float oscillatorReal = oscillatorReal_[index];
    const float oscillatorImaginary = oscillatorImaginary_[index];

    // correlation * conjugate(current oscillator) gives elapsed pulse phase.
    const float real = correlationReal * oscillatorReal +
                       correlationImaginary * oscillatorImaginary;
    const float imaginary = correlationImaginary * oscillatorReal -
                            correlationReal * oscillatorImaginary;
    float phase = static_cast<float>(
        std::atan2(static_cast<double>(imaginary), static_cast<double>(real)) /
        (2.0 * kPi));
    if (phase < 0.0F) phase += 1.0F;
    return phase;
}

void CausalRhythmClock::AdvanceOscillators() noexcept {
    for (std::size_t index = 0; index < kTempoCount; ++index) {
        const float real = oscillatorReal_[index];
        const float imaginary = oscillatorImaginary_[index];
        oscillatorReal_[index] = real * rotationReal_[index] -
                                 imaginary * rotationImaginary_[index];
        oscillatorImaginary_[index] = real * rotationImaginary_[index] +
                                      imaginary * rotationReal_[index];
    }

    // Bound long-session floating-point drift without trigonometry in steady
    // state. This branch runs roughly once every five seconds at 200 Hz.
    if ((hopsSeen_ & 1023U) == 0U) {
        for (std::size_t index = 0; index < kTempoCount; ++index) {
            const float real = oscillatorReal_[index];
            const float imaginary = oscillatorImaginary_[index];
            const float magnitude = std::sqrt(real * real + imaginary * imaginary);
            if (magnitude > 1.0e-6F) {
                oscillatorReal_[index] /= magnitude;
                oscillatorImaginary_[index] /= magnitude;
            }
        }
    }

    if (locked_ && trackedPhaseInitialized_) {
        const float bpm = static_cast<float>(
            kMinimumBpm + static_cast<uint32_t>(selectedTempoIndex_));
        trackedPhase_ = WrapPhase(
            trackedPhase_ + bpm * static_cast<float>(hopSize_) /
                (60.0F * static_cast<float>(sampleRate_)));
    }
}

void CausalRhythmClock::ResetPulseState() noexcept {
    correlationReal_.fill(0.0F);
    correlationImaginary_.fill(0.0F);
    eventCorrelationReal_.fill(0.0F);
    eventCorrelationImaginary_.fill(0.0F);
    hypothesisPosterior_.fill(0.0F);
    hypotheses_.fill({});
    activationMass_ = 0.0F;
    eventActivationMass_ = 0.0F;
    selectedTempoIndex_ = 0U;
    candidateTempoIndex_ = 0U;
    challengerTempoIndex_ = 0U;
    candidateValid_ = false;
    hopsSinceEvaluation_ = 0U;
    hopsSinceEvidence_ = 0U;
    hopsSinceEvidenceEvent_ = evidenceSeparationHops_;
    hopsSinceAcousticOnset_ = acousticOnsetSuppressionHops_ + 1U;
    evidenceEventCount_ = 0U;
    candidateStableEvaluations_ = 0U;
    challengerEvaluations_ = 0U;
    lowConfidenceEvaluations_ = 0U;
    coastingEvaluations_ = 0U;
    coastingAlignedEvents_ = 0U;
    beatEvidenceWindowHops_ = 0U;
    phaseSettlingHops_ = 0U;
    previousActivation_ = 0.0F;
    previousPhase_ = 0.0F;
    trackedPhase_ = 0.0F;
    confidence_ = 0.0F;
    locked_ = false;
    coasting_ = false;
    phaseInitialized_ = false;
    trackedPhaseInitialized_ = false;
    reinforcedThisCycle_ = false;
}

void CausalRhythmClock::Reset() noexcept {
    oscillatorReal_.fill(1.0F);
    oscillatorImaginary_.fill(0.0F);
    hopsSeen_ = 0U;
    ResetPulseState();
}

} // namespace moonlight::haptics::core
