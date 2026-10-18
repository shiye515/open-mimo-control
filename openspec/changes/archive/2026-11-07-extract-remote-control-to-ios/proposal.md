# Proposal: extract-remote-control-to-ios

## Why

本仓库的目标是一个开源的 Mimo 远程控制应用（iOS + Android，见 README）。DJI Mimo 官方 App 把相机远程控制与剪辑、素材库、社区等大量功能耦合在一起，iOS 端用户无法获得一个轻量、专注的远程控制工具。现在手上已有两个关键输入：官方 APK（`docs/DJI-Mimo-store-official-release-10001997_sec.apk`）可作协议分析来源，远程控制界面的运行截图（`docs/IMG_1926.PNG`）可作 UI/交互的验收基准，因此本变更把"提取远程控制能力并落地为独立 iOS 应用"作为第一个端到端交付。

## What Changes

- **逆向官方 APK，提取远程控制部分**（产出为文档，不搬运代码）：
  - 已确认 APK 结构：Java 层被加固（`###SOPHIX###`/`AppGuard` 加壳桩，`classes.dex` 263MB 为壳，AndroidManifest 加密，apktool 无法直接解码）；UI 层为 Flutter（`libapp.so` Dart AOT + 317 个 `flutter_assets`）；连接与协议核心在 Native 层（`libdjisdk_jni.so` 41MB、`libdjibase.so` 22MB、`libDJIVideoJNI.so` 4.7MB 等，未见加壳）。
  - 提取内容：相机 WiFi 连接与配对流程、控制通道（握手、命令帧格式、心跳）、直播预览流（传输方式、编解码）、状态遥测（电量/存储/信号/分辨率/录制时长）。
  - 产出：`docs/protocol/` 下的协议文档（连接、控制命令、视频流、状态字段），供 iOS 实现与后续 Android 复用。
- **在 `ios/` 壳工程中实现独立 iOS 应用 OpenMimoControl**：
  - 复刻截图（`docs/IMG_1926.PNG`）中的远程控制界面：全屏实时预览、顶部状态条（WiFi/电量/SD/录制时长、分辨率角标）、变焦指示（1.0x；OA4 实测无变焦命令——`02/B8` 为 Pocket 专用，按视场角/FOV 展示实现，见 specs/control-screen「视场角展示与变焦限制」）、底部模式栏（运动延时/延时摄影/慢动作/视频/照片可用，直播仅按截图保留入口）、红色录制按钮与回放入口（回放仅占位）。
  - Swift 原始实现（clean-room）：`Network.framework` 做连接与流接收、`VideoToolbox` 硬解视频、`NEHotspotConfiguration` 辅助入网。
- 明确**不在本变更范围**：直播模式与相机回放/文件下载（已确认不做，入口仅占位并明确提示未实现）、Android 应用实现（`android/` 保持为空）、剪辑/素材/社区等 Mimo 其他功能、App Store 上架（本变更面向真机侧载/个人使用）、DJI 专有代码或资源的复制与再分发。

## Capabilities

### New Capabilities

- `camera-connection`: iOS 设备发现并接入相机 WiFi、建立/断开控制会话（握手、心跳、重连），并向 UI 上报连接状态与遥测数据（电量、SD 状态、信号、录制时长、分辨率）。
- `live-view`: 接收相机实时视频流（传输层 + 解复用），VideoToolbox 硬解并低延迟渲染全屏预览，含画面比例/网格线等预览辅助。
- `control-screen`: 远程控制主界面（对应 IMG_1926.PNG）的布局与交互：模式选择栏、录制按钮、拍摄参数设置面板（曝光/白平衡/视频格式/延时参数等）、回放入口与设置入口，触发对应的控制命令并呈现执行结果（命令基线 = osmocam/osmo-client/osmosis 三开源仓库；OA4 无变焦命令，变焦指示按视场角展示实现）。

### Modified Capabilities

（无 —— 项目尚无既有 spec。）

## Impact

- **代码**：`ios/OpenMimoControl.xcodeproj`（新增 entitlement/权限配置、 Swift 模块：连接、协议编解码、视频管线、UI）；`ios/OpenMimoControl/` 现有模板代码（`ContentView.swift`）将被替换。
- **文档**：新增 `docs/protocol/`（协议分析文档）；`docs/` 下现有 APK/截图为分析输入，不修改。
- **依赖**：iOS 目标为 Swift/SwiftUI + 系统框架（Network、VideoToolbox、NetworkExtension），不引入第三方网络/解码库；逆向工具链使用本机已装的 jadx/apktool，动态分析可选 Frida（需 Android 真机/模拟器）。
- **外部系统**：DJI Osmo 相机（真实硬件）—— 协议结论需用真机抓包验证。
- **合规约束**：仅提取协议事实（格式、命令、端口、编解码参数），iOS 侧全部为原始实现，不复制 DJI 代码/资源/二进制；逆向用于自有设备互操作性，分析产物保存在本仓库文档中。
