// SPDX-License-Identifier: Apache-2.0

#include "moonlight_haptics/android_adapter.h"

#include "moonlight_haptics/audio_haptics.h"

#include <jni.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

namespace {

constexpr uint32_t kMaximumProcessFrames = 64U;
constexpr uint32_t kMaximumDrainFrames = 32U;
constexpr uint32_t kValuesPerFrame = 14U;

struct QueuedFrame {
    AhHapticFrame frame{};
    uint32_t generation = 0U;
    uint64_t producer_time_us = 0U;
};

uint64_t MonotonicTimeUs() noexcept {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

class SpscFrameQueue {
public:
    explicit SpscFrameQueue(uint32_t capacity)
        : capacity_(capacity),
          mask_(capacity - 1U),
          slots_(std::make_unique<QueuedFrame[]>(capacity)) {}

    bool Push(const AhHapticFrame& frame, uint32_t generation, uint64_t producer_time_us) {
        const uint64_t write = write_index_.load(std::memory_order_relaxed);
        if (write - read_index_.load(std::memory_order_acquire) >= capacity_) return false;
        QueuedFrame& destination = slots_[static_cast<size_t>(write & mask_)];
        destination.frame = frame;
        destination.generation = generation;
        destination.producer_time_us = producer_time_us;
        write_index_.store(write + 1U, std::memory_order_release);
        return true;
    }

    uint32_t Drain(
        AhHapticFrame* output,
        uint64_t* producer_times,
        uint32_t capacity,
        uint32_t generation) {
        uint32_t count = 0U;
        uint64_t read = read_index_.load(std::memory_order_relaxed);
        const uint64_t write = write_index_.load(std::memory_order_acquire);
        while (read < write && count < capacity) {
            const QueuedFrame& source = slots_[static_cast<size_t>(read & mask_)];
            if (source.generation == generation) {
                output[count] = source.frame;
                producer_times[count] = source.producer_time_us;
                ++count;
            }
            ++read;
        }
        read_index_.store(read, std::memory_order_release);
        return count;
    }

    bool HasPending() const {
        return read_index_.load(std::memory_order_acquire) <
            write_index_.load(std::memory_order_acquire);
    }

    void ClearFromConsumer() {
        read_index_.store(write_index_.load(std::memory_order_acquire),
                          std::memory_order_release);
    }

private:
    const uint64_t capacity_;
    const uint64_t mask_;
    std::unique_ptr<QueuedFrame[]> slots_;
    alignas(64) std::atomic<uint64_t> read_index_{0U};
    alignas(64) std::atomic<uint64_t> write_index_{0U};
};

bool IsPowerOfTwo(uint32_t value) {
    return value >= 2U && (value & (value - 1U)) == 0U;
}

uint32_t ClampScene(uint32_t scene) {
    return std::min(scene, static_cast<uint32_t>(AH_SCENE_AUTO));
}

uint32_t FloatToBits(float value) noexcept {
    uint32_t bits = 0U;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float BitsToFloat(uint32_t bits) noexcept {
    float value = 0.0F;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

float ClampSensitivity(float sensitivity) noexcept {
    return std::clamp(sensitivity, 0.1F, 3.0F);
}

} // namespace

struct MhAndroidSession {
    MhAndroidSession(
        JavaVM* java_vm,
        jobject callback_object,
        jmethodID notify_method,
        uint32_t scene,
        float requested_sensitivity,
        float requested_output_gain,
        uint32_t queue_capacity)
        : queue(queue_capacity),
          requested_scene(ClampScene(scene)),
          requested_sensitivity_bits(FloatToBits(ClampSensitivity(requested_sensitivity))),
          output_gain(requested_output_gain),
          vm(java_vm),
          callback(callback_object),
          notify_method_id(notify_method) {}

    ~MhAndroidSession() {
        if (engine != nullptr) ah_destroy(engine);
    }

    std::atomic<uint32_t> references{1U};
    SpscFrameQueue queue;
    std::atomic<uint32_t> requested_scene;
    std::atomic<uint32_t> requested_sensitivity_bits;
    const float output_gain;
    std::atomic<uint32_t> generation{1U};
    std::atomic<uint64_t> dropped_frames{0U};
    std::atomic<uint64_t> process_errors{0U};
    std::atomic<bool> notification_required{false};
    std::atomic<bool> emergency_stop{false};
    std::atomic<uint64_t> emergency_stop_timestamp_us{0U};
    std::atomic<uint64_t> emergency_stop_producer_time_us{0U};
    std::atomic<uint32_t> emergency_stop_scene{AH_SCENE_UNKNOWN};
    std::atomic<bool> closed{false};

    // Audio-producer-thread-only state.
    AhEngine* engine = nullptr;
    AhConfig config{};
    uint32_t sample_rate = 0U;
    uint32_t channel_count = 0U;
    uint32_t applied_scene = AH_SCENE_UNKNOWN;
    uint64_t timeline_us = 0U;
    uint64_t timeline_remainder = 0U;

    JavaVM* vm = nullptr;
    jobject callback = nullptr;
    jmethodID notify_method_id = nullptr;
};

extern "C" {

void mh_android_session_acquire(MhAndroidSession* session) {
    if (session != nullptr) session->references.fetch_add(1U, std::memory_order_relaxed);
}

void mh_android_session_release(MhAndroidSession* session) {
    if (session != nullptr &&
        session->references.fetch_sub(1U, std::memory_order_acq_rel) == 1U) {
        delete session;
    }
}

int32_t mh_android_session_configure(
    MhAndroidSession* session,
    uint32_t sample_rate,
    uint32_t channel_count) {
    if (session == nullptr || session->closed.load(std::memory_order_acquire) ||
        sample_rate == 0U || channel_count == 0U) {
        return static_cast<int32_t>(AH_STATUS_INVALID_ARGUMENT);
    }

    if (session->engine != nullptr) {
        ah_destroy(session->engine);
        session->engine = nullptr;
    }
    session->generation.fetch_add(1U, std::memory_order_acq_rel);
    session->sample_rate = sample_rate;
    session->channel_count = channel_count;
    session->timeline_remainder = 0U;

    AhStatus status = ah_config_init(&session->config, sample_rate, channel_count);
    if (status == AH_STATUS_OK) {
        session->config.requested_scene = session->requested_scene.load(std::memory_order_acquire);
        session->config.sensitivity = BitsToFloat(
            session->requested_sensitivity_bits.load(std::memory_order_acquire));
        session->config.output_gain = session->output_gain;
        status = ah_create(&session->config, &session->engine);
    }
    if (status == AH_STATUS_OK) {
        session->applied_scene = session->config.requested_scene;
    } else {
        session->process_errors.fetch_add(1U, std::memory_order_relaxed);
    }
    return static_cast<int32_t>(status);
}

void mh_android_session_reset(MhAndroidSession* session) {
    if (session == nullptr) return;
    if (session->engine != nullptr) {
        ah_destroy(session->engine);
        session->engine = nullptr;
    }
    session->sample_rate = 0U;
    session->channel_count = 0U;
    session->timeline_remainder = 0U;
    session->applied_scene = AH_SCENE_UNKNOWN;
    session->generation.fetch_add(1U, std::memory_order_acq_rel);
}

void mh_android_session_set_scene(MhAndroidSession* session, uint32_t scene) {
    if (session != nullptr) {
        session->requested_scene.store(ClampScene(scene), std::memory_order_release);
    }
}

void mh_android_session_set_sensitivity(MhAndroidSession* session, float sensitivity) {
    if (session != nullptr) {
        session->requested_sensitivity_bits.store(
            FloatToBits(ClampSensitivity(sensitivity)), std::memory_order_release);
    }
}

int32_t mh_android_session_process_i16(
    MhAndroidSession* session,
    const int16_t* interleaved_pcm,
    uint32_t frame_count) {
    if (session == nullptr || session->closed.load(std::memory_order_acquire) ||
        session->engine == nullptr || interleaved_pcm == nullptr || frame_count == 0U) {
        return 0;
    }

    const uint32_t scene = session->requested_scene.load(std::memory_order_acquire);
    const float sensitivity = BitsToFloat(
        session->requested_sensitivity_bits.load(std::memory_order_acquire));
    if (scene != session->applied_scene || sensitivity != session->config.sensitivity) {
        AhConfig updated = session->config;
        updated.requested_scene = scene;
        updated.sensitivity = sensitivity;
        const AhStatus update_status = ah_update_config(session->engine, &updated);
        if (update_status == AH_STATUS_OK) {
            session->config = updated;
            session->applied_scene = scene;
        } else {
            session->process_errors.fetch_add(1U, std::memory_order_relaxed);
        }
    }

    const uint64_t first_sample_time_us = session->timeline_us;
    AhProcessInput input{};
    input.struct_size = AH_PROCESS_INPUT_V1_SIZE;
    input.interleaved_pcm = interleaved_pcm;
    input.frame_count = frame_count;
    input.first_sample_time_us = first_sample_time_us;

    std::array<AhHapticFrame, kMaximumProcessFrames> frames{};
    uint32_t output_count = 0U;
    AhStatus status = AH_STATUS_BUFFER_TOO_SMALL;
    const uint32_t required = ah_get_max_output_frames(session->engine, frame_count);
    if (required <= frames.size()) {
        status = ah_process_i16(
            session->engine,
            &input,
            frames.data(),
            static_cast<uint32_t>(frames.size()),
            &output_count);
    }
    const uint64_t elapsed_numerator = session->timeline_remainder +
        static_cast<uint64_t>(frame_count) * 1000000ULL;
    session->timeline_us += elapsed_numerator / session->sample_rate;
    session->timeline_remainder = elapsed_numerator % session->sample_rate;
    if (status != AH_STATUS_OK && status != AH_STATUS_OUTPUT_AVAILABLE) {
        session->process_errors.fetch_add(1U, std::memory_order_relaxed);
        return static_cast<int32_t>(status);
    }

    const uint32_t generation = session->generation.load(std::memory_order_acquire);
    uint32_t accepted = 0U;
    for (uint32_t index = 0U; index < output_count; ++index) {
        const uint64_t producer_time_us = MonotonicTimeUs();
        if (session->queue.Push(frames[index], generation, producer_time_us)) {
            ++accepted;
            continue;
        }
        session->dropped_frames.fetch_add(1U, std::memory_order_relaxed);
        if ((frames[index].flags & AH_FRAME_STOP) != 0U) {
            session->emergency_stop_timestamp_us.store(
                frames[index].timestamp_us, std::memory_order_relaxed);
            session->emergency_stop_producer_time_us.store(
                producer_time_us, std::memory_order_relaxed);
            session->emergency_stop_scene.store(
                frames[index].active_scene, std::memory_order_relaxed);
            session->emergency_stop.store(true, std::memory_order_release);
        }
    }
    if (accepted > 0U || session->emergency_stop.load(std::memory_order_acquire)) {
        session->notification_required.store(true, std::memory_order_release);
    }
    return static_cast<int32_t>(accepted);
}

void mh_android_session_notify(MhAndroidSession* session) {
    if (session == nullptr || session->closed.load(std::memory_order_acquire) ||
        !session->notification_required.exchange(false, std::memory_order_acq_rel) ||
        session->callback == nullptr || session->notify_method_id == nullptr) {
        return;
    }

    JNIEnv* env = nullptr;
    if (session->vm == nullptr ||
        session->vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK ||
        env == nullptr) {
        session->notification_required.store(true, std::memory_order_release);
        return;
    }
    env->CallVoidMethod(session->callback, session->notify_method_id);
    if (env->ExceptionCheck()) env->ExceptionClear();
}

uint64_t mh_android_session_dropped_frames(const MhAndroidSession* session) {
    return session == nullptr ? 0U :
        session->dropped_frames.load(std::memory_order_relaxed);
}

} // extern "C"

namespace {

uint32_t DrainFrames(
    MhAndroidSession* session,
    AhHapticFrame* output,
    uint64_t* producer_times,
    uint32_t capacity) {
    if (session == nullptr || output == nullptr || producer_times == nullptr || capacity == 0U) {
        return 0U;
    }
    const uint32_t generation = session->generation.load(std::memory_order_acquire);
    if (session->emergency_stop.exchange(false, std::memory_order_acq_rel)) {
        session->queue.ClearFromConsumer();
        AhHapticFrame& stop = output[0];
        stop = AhHapticFrame{};
        stop.struct_size = AH_HAPTIC_FRAME_V1_SIZE;
        stop.flags = AH_FRAME_STOP;
        stop.timestamp_us = session->emergency_stop_timestamp_us.load(std::memory_order_relaxed);
        stop.active_scene = session->emergency_stop_scene.load(std::memory_order_relaxed);
        producer_times[0] = session->emergency_stop_producer_time_us.load(
            std::memory_order_relaxed);
        return 1U;
    }
    return session->queue.Drain(output, producer_times, capacity, generation);
}

bool HasPending(const MhAndroidSession* session) {
    return session != nullptr &&
        (session->emergency_stop.load(std::memory_order_acquire) || session->queue.HasPending());
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeCreate(
    JNIEnv* env,
    jobject instance,
    jint scene,
    jfloat sensitivity,
    jfloat output_gain,
    jint queue_capacity) {
    const uint32_t capacity = queue_capacity > 0 ? static_cast<uint32_t>(queue_capacity) : 0U;
    if (!IsPowerOfTwo(capacity) || capacity > 1024U) return 0;

    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK || vm == nullptr) return 0;
    jobject callback = env->NewGlobalRef(instance);
    if (callback == nullptr) return 0;
    jclass clazz = env->GetObjectClass(instance);
    jmethodID notify_method = clazz == nullptr ? nullptr :
        env->GetMethodID(clazz, "onNativeFramesAvailable", "()V");
    if (clazz != nullptr) env->DeleteLocalRef(clazz);
    if (notify_method == nullptr) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteGlobalRef(callback);
        return 0;
    }

    MhAndroidSession* session = nullptr;
    try {
        session = new MhAndroidSession(
            vm,
            callback,
            notify_method,
            ClampScene(static_cast<uint32_t>(std::max(scene, 0))),
            std::clamp(static_cast<float>(sensitivity), 0.1F, 3.0F),
            std::clamp(static_cast<float>(output_gain), 0.0F, 1.0F),
            capacity);
    } catch (...) {
        env->DeleteGlobalRef(callback);
        return 0;
    }
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(session));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeDrain(
    JNIEnv* env,
    jobject,
    jlong handle,
    jlongArray timestamps_array,
    jlongArray producer_times_array,
    jintArray metadata_array,
    jfloatArray values_array,
    jint requested_capacity) {
    auto* session = reinterpret_cast<MhAndroidSession*>(static_cast<uintptr_t>(handle));
    const uint32_t capacity = static_cast<uint32_t>(
        std::clamp(requested_capacity, 0, static_cast<jint>(kMaximumDrainFrames)));
    if (session == nullptr || capacity == 0U ||
        env->GetArrayLength(timestamps_array) < static_cast<jsize>(capacity) ||
        env->GetArrayLength(producer_times_array) < static_cast<jsize>(capacity) ||
        env->GetArrayLength(metadata_array) < static_cast<jsize>(capacity * 2U) ||
        env->GetArrayLength(values_array) < static_cast<jsize>(capacity * kValuesPerFrame)) {
        return 0;
    }

    std::array<AhHapticFrame, kMaximumDrainFrames> frames{};
    std::array<uint64_t, kMaximumDrainFrames> native_producer_times{};
    const uint32_t count = DrainFrames(
        session, frames.data(), native_producer_times.data(), capacity);
    std::array<jlong, kMaximumDrainFrames> timestamps{};
    std::array<jlong, kMaximumDrainFrames> producer_times{};
    std::array<jint, kMaximumDrainFrames * 2U> metadata{};
    std::array<jfloat, kMaximumDrainFrames * kValuesPerFrame> values{};
    for (uint32_t index = 0U; index < count; ++index) {
        const AhHapticFrame& frame = frames[index];
        timestamps[index] = static_cast<jlong>(frame.timestamp_us);
        producer_times[index] = static_cast<jlong>(native_producer_times[index]);
        metadata[index * 2U] = static_cast<jint>(frame.flags);
        metadata[index * 2U + 1U] = static_cast<jint>(frame.active_scene);
        const size_t base = static_cast<size_t>(index * kValuesPerFrame);
        values[base] = frame.continuous_amplitude;
        values[base + 1U] = frame.transient_amplitude;
        values[base + 2U] = frame.transient_duration_ms;
        values[base + 3U] = frame.sharpness;
        values[base + 4U] = frame.low_band_ratio;
        values[base + 5U] = frame.stereo_pan;
        values[base + 6U] = frame.confidence;
        std::memcpy(&values[base + 7U], &frame.reserved[0], sizeof(float));
        std::memcpy(&values[base + 8U], &frame.reserved[1], sizeof(float));
        std::memcpy(&values[base + 9U], &frame.reserved[2], sizeof(float));
        values[base + 10U] = frame.reserved[3] != 0U ? 1.0F : 0.0F;
        std::memcpy(&values[base + 11U], &frame.reserved[4], sizeof(float));
        std::memcpy(&values[base + 12U], &frame.reserved[5], sizeof(float));
        values[base + 13U] = frame.reserved[6] != 0U ? 1.0F : 0.0F;
    }
    env->SetLongArrayRegion(timestamps_array, 0, static_cast<jsize>(count), timestamps.data());
    env->SetLongArrayRegion(
        producer_times_array, 0, static_cast<jsize>(count), producer_times.data());
    env->SetIntArrayRegion(metadata_array, 0, static_cast<jsize>(count * 2U), metadata.data());
    env->SetFloatArrayRegion(
        values_array, 0, static_cast<jsize>(count * kValuesPerFrame), values.data());
    return static_cast<jint>(count);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeHasPending(
    JNIEnv*, jobject, jlong handle) {
    const auto* session = reinterpret_cast<const MhAndroidSession*>(
        static_cast<uintptr_t>(handle));
    return HasPending(session) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeClear(
    JNIEnv*, jobject, jlong handle) {
    auto* session = reinterpret_cast<MhAndroidSession*>(static_cast<uintptr_t>(handle));
    if (session != nullptr) {
        session->queue.ClearFromConsumer();
        session->emergency_stop.store(false, std::memory_order_release);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeSetScene(
    JNIEnv*, jobject, jlong handle, jint scene) {
    auto* session = reinterpret_cast<MhAndroidSession*>(static_cast<uintptr_t>(handle));
    mh_android_session_set_scene(
        session, ClampScene(static_cast<uint32_t>(std::max(scene, 0))));
}

extern "C" JNIEXPORT void JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeSetSensitivity(
    JNIEnv*, jobject, jlong handle, jfloat sensitivity) {
    auto* session = reinterpret_cast<MhAndroidSession*>(static_cast<uintptr_t>(handle));
    mh_android_session_set_sensitivity(session, static_cast<float>(sensitivity));
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeDroppedFrames(
    JNIEnv*, jobject, jlong handle) {
    const auto* session = reinterpret_cast<const MhAndroidSession*>(
        static_cast<uintptr_t>(handle));
    return static_cast<jlong>(mh_android_session_dropped_frames(session));
}

extern "C" JNIEXPORT void JNICALL
Java_com_moonlight_haptics_android_NativeHapticsSession_nativeClose(
    JNIEnv* env, jobject, jlong handle) {
    auto* session = reinterpret_cast<MhAndroidSession*>(static_cast<uintptr_t>(handle));
    if (session == nullptr || session->closed.exchange(true, std::memory_order_acq_rel)) return;
    session->generation.fetch_add(1U, std::memory_order_acq_rel);
    if (session->callback != nullptr) {
        env->DeleteGlobalRef(session->callback);
        session->callback = nullptr;
    }
    session->notify_method_id = nullptr;
    mh_android_session_release(session);
}
