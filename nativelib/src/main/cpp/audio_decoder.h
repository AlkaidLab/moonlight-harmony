#ifndef AUDIO_DECODER_H
#define AUDIO_DECODER_H

#include <napi/native_api.h>

/**
 * 音频解码器
 * 
 * 使用 HarmonyOS OHAudio API 播放音频
 */
class AudioDecoder {
public:
    // 设置音频解码器
    static napi_value Setup(napi_env env, napi_callback_info info);
    
    // 启动播放
    static napi_value Start(napi_env env, napi_callback_info info);
    
    // 停止播放
    static napi_value Stop(napi_env env, napi_callback_info info);
    
private:
    // TODO: OHAudio 相关成员变量
};

#endif // AUDIO_DECODER_H
