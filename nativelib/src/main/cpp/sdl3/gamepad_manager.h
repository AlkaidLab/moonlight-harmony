/**
 * SDL3 游戏手柄管理器
 * 
 * 使用 SDL3 的 Gamepad/Joystick API 处理手柄输入
 */

#ifndef GAMEPAD_MANAGER_H
#define GAMEPAD_MANAGER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 手柄状态结构
typedef struct {
    int32_t deviceId;
    uint32_t buttons;
    int16_t leftStickX;
    int16_t leftStickY;
    int16_t rightStickX;
    int16_t rightStickY;
    uint8_t leftTrigger;
    uint8_t rightTrigger;
} GamepadState;

// 手柄信息结构
typedef struct {
    int32_t deviceId;
    char name[256];
    uint16_t vendorId;
    uint16_t productId;
    int type;  // 0=Unknown, 1=Xbox, 2=PS, 3=Nintendo
    bool isGamepad;  // true=SDL_Gamepad, false=SDL_Joystick
} GamepadInfo;

// 按钮标志位 (与 Moonlight 协议兼容)
#define GAMEPAD_UP_FLAG         0x0001
#define GAMEPAD_DOWN_FLAG       0x0002
#define GAMEPAD_LEFT_FLAG       0x0004
#define GAMEPAD_RIGHT_FLAG      0x0008
#define GAMEPAD_START_FLAG      0x0010
#define GAMEPAD_BACK_FLAG       0x0020
#define GAMEPAD_LS_CLK_FLAG     0x0040
#define GAMEPAD_RS_CLK_FLAG     0x0080
#define GAMEPAD_LB_FLAG         0x0100
#define GAMEPAD_RB_FLAG         0x0200
#define GAMEPAD_GUIDE_FLAG      0x0400
#define GAMEPAD_A_FLAG          0x1000
#define GAMEPAD_B_FLAG          0x2000
#define GAMEPAD_X_FLAG          0x4000
#define GAMEPAD_Y_FLAG          0x8000

// 回调函数类型
typedef void (*GamepadConnectedCallback)(const GamepadInfo* info);
typedef void (*GamepadDisconnectedCallback)(int32_t deviceId);
typedef void (*GamepadStateCallback)(const GamepadState* state);

/**
 * 初始化手柄管理器
 * @return 0 成功, -1 失败
 */
int GamepadManager_Init(void);

/**
 * 关闭手柄管理器
 */
void GamepadManager_Quit(void);

/**
 * 设置回调函数
 */
void GamepadManager_SetConnectedCallback(GamepadConnectedCallback callback);
void GamepadManager_SetDisconnectedCallback(GamepadDisconnectedCallback callback);
void GamepadManager_SetStateCallback(GamepadStateCallback callback);

/**
 * 轮询并处理手柄事件
 * 应该定期调用此函数（例如每帧或每 16ms）
 */
void GamepadManager_PollEvents(void);

/**
 * 获取已连接的手柄数量
 */
int GamepadManager_GetConnectedCount(void);

/**
 * 获取手柄信息
 * @param index 手柄索引 (0 到 GetConnectedCount-1)
 * @param info 输出手柄信息
 * @return 0 成功, -1 失败
 */
int GamepadManager_GetInfo(int index, GamepadInfo* info);

/**
 * 获取手柄状态
 * @param deviceId 设备 ID
 * @param state 输出状态
 * @return 0 成功, -1 失败
 */
int GamepadManager_GetState(int32_t deviceId, GamepadState* state);

/**
 * 设置手柄震动
 * @param deviceId 设备 ID
 * @param lowFreq 低频电机 (0-65535)
 * @param highFreq 高频电机 (0-65535)
 * @param durationMs 持续时间（毫秒），0 表示持续震动
 * @return 0 成功, -1 失败
 */
int GamepadManager_Rumble(int32_t deviceId, uint16_t lowFreq, uint16_t highFreq, uint32_t durationMs);

/**
 * 打开指定的 USB 设备作为手柄
 * 用于 HarmonyOS 上手动打开 USB 设备
 * @param vendorId 厂商 ID
 * @param productId 产品 ID
 * @param fd 文件描述符 (从 usbManager 获取)
 * @return deviceId 成功, -1 失败
 */
int GamepadManager_OpenUsbDevice(uint16_t vendorId, uint16_t productId, int fd);

/**
 * 关闭指定的 USB 设备
 */
void GamepadManager_CloseUsbDevice(int32_t deviceId);

#ifdef __cplusplus
}
#endif

#endif // GAMEPAD_MANAGER_H
