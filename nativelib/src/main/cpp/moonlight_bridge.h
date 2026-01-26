#ifndef MOONLIGHT_BRIDGE_H
#define MOONLIGHT_BRIDGE_H

#include <napi/native_api.h>

/**
 * Moonlight 桥接层
 * 
 * 连接 ArkTS 层和 moonlight-common-c 核心库
 */
class MoonlightBridge {
public:
    // 初始化 Moonlight 库
    static napi_value Initialize(napi_env env, napi_callback_info info);
    
    // 连接到服务器
    static napi_value Connect(napi_env env, napi_callback_info info);
    
    // 断开连接
    static napi_value Disconnect(napi_env env, napi_callback_info info);
    
    // 获取统计信息
    static napi_value GetStats(napi_env env, napi_callback_info info);
    
private:
    static bool initialized_;
    static bool connected_;
};

#endif // MOONLIGHT_BRIDGE_H
