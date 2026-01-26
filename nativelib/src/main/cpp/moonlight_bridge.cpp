#include "moonlight_bridge.h"
#include <hilog/log.h>
#include <cstring>

#define LOG_TAG "MoonlightBridge"

bool MoonlightBridge::initialized_ = false;
bool MoonlightBridge::connected_ = false;

/**
 * 初始化 Moonlight 库
 * 
 * @param env NAPI 环境
 * @param info 回调信息
 * @return 初始化结果 (boolean)
 */
napi_value MoonlightBridge::Initialize(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonlightBridge::Initialize");
    
    // TODO: 初始化 moonlight-common-c
    // LiInitialize();
    
    initialized_ = true;
    
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

/**
 * 连接到串流服务器
 * 
 * 参数:
 * - serverInfo: 服务器信息对象
 * - streamConfig: 串流配置对象
 * 
 * @param env NAPI 环境
 * @param info 回调信息
 * @return Promise
 */
napi_value MoonlightBridge::Connect(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonlightBridge::Connect");
    
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "需要 serverInfo 和 streamConfig 参数");
        return nullptr;
    }
    
    // TODO: 解析参数并调用 moonlight-common-c
    /*
    SERVER_INFORMATION serverInfo;
    STREAM_CONFIGURATION streamConfig;
    
    // 解析 serverInfo
    napi_value hostValue;
    napi_get_named_property(env, args[0], "host", &hostValue);
    // ...
    
    // 开始连接
    int result = LiStartConnection(
        &serverInfo,
        &streamConfig,
        &connectionCallbacks,
        &platformInfo
    );
    */
    
    connected_ = true;
    
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

/**
 * 断开连接
 */
napi_value MoonlightBridge::Disconnect(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "MoonlightBridge::Disconnect");
    
    if (!connected_) {
        napi_value result;
        napi_get_boolean(env, true, &result);
        return result;
    }
    
    // TODO: 调用 moonlight-common-c 断开连接
    // LiStopConnection();
    
    connected_ = false;
    
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

/**
 * 获取串流统计信息
 * 
 * @return 包含 fps, bitrate, latency, packetLoss 等字段的对象
 */
napi_value MoonlightBridge::GetStats(napi_env env, napi_callback_info info) {
    napi_value statsObj;
    napi_create_object(env, &statsObj);
    
    // TODO: 从 moonlight-common-c 获取实际统计信息
    // STREAMING_STATS stats;
    // LiGetStats(&stats);
    
    // 暂时返回模拟数据
    napi_value fps, bitrate, latency, packetLoss;
    napi_create_int32(env, 60, &fps);
    napi_create_int32(env, 20000, &bitrate);
    napi_create_int32(env, 15, &latency);
    napi_create_double(env, 0.1, &packetLoss);
    
    napi_set_named_property(env, statsObj, "fps", fps);
    napi_set_named_property(env, statsObj, "bitrate", bitrate);
    napi_set_named_property(env, statsObj, "latency", latency);
    napi_set_named_property(env, statsObj, "packetLoss", packetLoss);
    
    return statsObj;
}
