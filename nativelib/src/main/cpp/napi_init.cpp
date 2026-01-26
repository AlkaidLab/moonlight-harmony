/**
 * NAPI 模块初始化
 * 
 * 这是 HarmonyOS Native 模块的入口点
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include "moonlight_bridge.h"
#include "video_decoder.h"
#include "audio_decoder.h"
#include "input_handler.h"

#define LOG_TAG "MoonlightNative"
#define LOG_DOMAIN 0x0000

// 日志宏
#define LOGI(...) OH_LOG_INFO(LOG_USER, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_USER, __VA_ARGS__)

// 模块方法声明
static napi_value Init(napi_env env, napi_value exports);

// 定义模块
NAPI_MODULE(moonlight_nativelib, Init)

/**
 * 初始化模块，导出所有 NAPI 方法
 */
static napi_value Init(napi_env env, napi_value exports) {
    LOGI("Moonlight Native 模块初始化");
    
    // 导出方法
    napi_property_descriptor desc[] = {
        // 连接管理
        { "initialize", nullptr, MoonlightBridge::Initialize, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "connect", nullptr, MoonlightBridge::Connect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "disconnect", nullptr, MoonlightBridge::Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getStats", nullptr, MoonlightBridge::GetStats, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 视频解码
        { "setupVideoDecoder", nullptr, VideoDecoder::Setup, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startVideoDecoder", nullptr, VideoDecoder::Start, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopVideoDecoder", nullptr, VideoDecoder::Stop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setVideoSurface", nullptr, VideoDecoder::SetSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 音频解码
        { "setupAudioDecoder", nullptr, AudioDecoder::Setup, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startAudioDecoder", nullptr, AudioDecoder::Start, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopAudioDecoder", nullptr, AudioDecoder::Stop, nullptr, nullptr, nullptr, napi_default, nullptr },
        
        // 输入处理
        { "sendMouseMove", nullptr, InputHandler::SendMouseMove, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMouseButton", nullptr, InputHandler::SendMouseButton, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendMouseScroll", nullptr, InputHandler::SendMouseScroll, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendKeyboard", nullptr, InputHandler::SendKeyboard, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendController", nullptr, InputHandler::SendController, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sendTouch", nullptr, InputHandler::SendTouch, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    
    return exports;
}
