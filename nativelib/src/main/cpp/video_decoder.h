#ifndef VIDEO_DECODER_H
#define VIDEO_DECODER_H

#include <napi/native_api.h>

/**
 * 视频解码器
 * 
 * 使用 HarmonyOS AVCodec API 进行硬件解码
 */
class VideoDecoder {
public:
    // 设置视频解码器
    static napi_value Setup(napi_env env, napi_callback_info info);
    
    // 启动解码器
    static napi_value Start(napi_env env, napi_callback_info info);
    
    // 停止解码器
    static napi_value Stop(napi_env env, napi_callback_info info);
    
    // 设置输出 Surface
    static napi_value SetSurface(napi_env env, napi_callback_info info);
    
private:
    // TODO: AVCodec 相关成员变量
};

#endif // VIDEO_DECODER_H
