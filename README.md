# YueyeShedeng

智能越野射灯系统 —— 安卓 App（Flutter）+ ESP32-C3 固件，蓝牙控制车上 8 个灯位的射灯。

## 仓库结构

| 目录 | 说明 |
|---|---|
| [`offroad_light/`](offroad_light/) | **安卓 App**（Flutter）。车图分组控制 + 单灯控制 + 五种模式 |
| [`smart_spotlight_ble/`](smart_spotlight_ble/) | **ESP32-C3 新固件**。BLE 手机控制 + 灯位独立开关 + NVS 记忆 + 状态上报 |
| [`smart_spotlight_c3/`](smart_spotlight_c3/) | 旧固件（语音 + 传感器版），保留不动 |
| `main.py` | K230 上的 AI 视觉版本，保留不动 |

App 和固件的详细说明、协议表、接线图见 [offroad_light/README.md](offroad_light/README.md)。

## 拿 APK

推到 `main` 分支会自动触发构建，在 **Actions** 页面该次运行的底部 Artifacts 里下载
`SPOTLIGHT-android`，直接装手机。也可以在 Actions 里手动 Run workflow。

## 开始之前

把越野车实拍图放进 `offroad_light/assets/images/`（文件名随便，首选 `car.png`），
App 主页会用它当背景，灯位光点自动叠在车上对应位置。
