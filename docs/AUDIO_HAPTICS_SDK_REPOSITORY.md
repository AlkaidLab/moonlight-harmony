# Audio Haptics SDK 仓库迁移

Audio Haptics SDK 已从本仓库的 `audio-haptics-sdk/` 迁移到独立的
[AlkaidLab/moonlight-audio-haptics](https://github.com/AlkaidLab/moonlight-audio-haptics)。

当前宿主验证基线：

- Release：[`v0.5.14`](https://github.com/AlkaidLab/moonlight-audio-haptics/releases/tag/v0.5.14)
- Commit：`e243a6ce65d6dec35976ca0eace3c5aff0d82cc4`
- C ABI：v1
- 参数集：`action-rpg-p4g-v4`
- 许可证：Apache License 2.0

## 本地目录

推荐把两个仓库并列放置：

```text
StudioProjects/
├─ moonlight-harmonyos/
└─ moonlight-audio-haptics/
```

此布局会被 HarmonyOS 模块和评测工具自动识别。使用其他目录时设置：

```powershell
$env:AUDIO_HAPTICS_SDK_DIR = 'D:\src\moonlight-audio-haptics'
```

或在配置评测工具时传入：

```bash
cmake -S tools/audio_haptics_eval -B build/audio-haptics-eval \
  -DAUDIO_HAPTICS_SDK_DIR=/path/to/moonlight-audio-haptics
```

CI 和发布构建必须固定完整 commit SHA；tag 只作为可读版本标识。SDK
算法、ABI、Android AAR、许可证和发布资产由独立仓库负责，本仓库继续负责
HarmonyOS PCM 接入、生命周期、产品策略和宿主评测。
