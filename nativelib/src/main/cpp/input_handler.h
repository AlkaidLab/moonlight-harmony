#ifndef INPUT_HANDLER_H
#define INPUT_HANDLER_H

#include <napi/native_api.h>

/**
 * 输入处理器
 * 
 * 处理鼠标、键盘、手柄、触控等输入并发送给服务器
 */
class InputHandler {
public:
    // 发送鼠标移动
    static napi_value SendMouseMove(napi_env env, napi_callback_info info);
    
    // 发送鼠标按钮
    static napi_value SendMouseButton(napi_env env, napi_callback_info info);
    
    // 发送鼠标滚轮
    static napi_value SendMouseScroll(napi_env env, napi_callback_info info);
    
    // 发送键盘事件
    static napi_value SendKeyboard(napi_env env, napi_callback_info info);
    
    // 发送手柄事件
    static napi_value SendController(napi_env env, napi_callback_info info);
    
    // 发送触控事件
    static napi_value SendTouch(napi_env env, napi_callback_info info);
};

#endif // INPUT_HANDLER_H
