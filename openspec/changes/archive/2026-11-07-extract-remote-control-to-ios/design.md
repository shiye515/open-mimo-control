# Design: extract-remote-control-to-ios

## Context

官方 APK 已完成初步侦察（详见 proposal）：

| 层 | 现状 | 可分析性 |
| --- | --- | --- |
| Java/Kotlin | Sophix/AppGuard 加固：`classes.dex` 为 263MB 壳桩，AndroidManifest 加密 | 静态不可读，需运行时脱壳 |
| Flutter UI | `libapp.so`（8.3MB Dart AOT）+ 317 个 `flutter_assets` | 可用 blutter/reFlutter 恢复类名与字符串 |
| Native 协议层 | `libdjisdk_jni.so`(41MB)、`libdjibase.so`(22MB)、`libDJIVideoJNI.so`(4.7MB)、`libassemble_proto.so`、`libilink_live.so` | 未见加壳，可直接字符串/符号分析 |

本机工具链已就绪：jadx、apktool、java、python3。iOS 侧为空白 SwiftUI 壳工程（`ios/OpenMimoControl`）。真机硬件（Osmo 相机）可配合动态验证。

**Clean-room 约束**：整个流程只产出"协议事实"（端口、帧格式、命令语义、编解码参数），iOS 代码全部原创；不复制、不反编译移植 DJI 的代码、资源、二进制到本仓库实现中；分析中间产物（脱壳 dex、反编译文本）只存在于本机临时目录，不入库。

## Goals / Non-Goals

**Goals:**
- 逆向产出 `docs/protocol/` 四份文档：`discovery.md`（发现/入网）、`control-channel.md`（控制通道与命令）、`live-view.md`（视频流）、`telemetry.md`(状态遥测)。
- iOS 应用达到 specs 定义的行为：连接、实时预览、录制/拍照/模式/拍摄参数设置（曝光/白平衡/格式/延时等，见 D-ctrl）、断连处理。
- 协议层以可替换抽象封装，未来 Android 实现复用同一份协议文档。

**Non-Goals:**
- 直播模式与相机回放/文件下载（用户已确认不做）：直播在模式栏仅保留入口、点击提示未实现；回放入口仅占位。协议文档不覆盖直播推流与文件传输协议。
- 素材库、剪辑、社区等 Mimo 外围功能（入口占位即可）。
- 多机型适配矩阵：本变更以手上这台相机为验证基准（截图对应机型），协议文档按机型字段留扩展位。
- App Store 合规、签名分发自动化。

## Decisions

### D1. 逆向方法：四路并进，以动态抓包为最终裁判
1. **Native 字符串/符号优先**：`libdjisdk_jni.so`、`libDJIVideoJNI.so` 直接 `strings` + 导出符号表 + Ghidra/objdump 定点分析，找协议常量（端口、魔数、命令字）。Java 层加固但 Native 没有加固，这是最快的入口。
2. **Flutter AOT 辅助**：用 blutter 恢复 `libapp.so` 的类名/字符串，定位远程控制页面的方法名与命令封装（Flutter 层通常只做 UI 编排，能提供命令语义的命名线索）。
3. **Java 层运行时脱壳（可选加强）**：Android 真机/模拟器 + Frida `frida-dexdump` 转储解密后的 dex，jadx 恢复业务类。仅在 1/2 不足以确定协议时启用。
4. **真机抓包定案**：手机连接相机热点后用 pcap 抓包（Android 上 tcpdump，或笔记本桥接），确认端口、传输层（TCP/UDP）、握手序列、视频流封装。**所有协议结论以抓包为准，静态分析只提供线索与语义命名。**

理由：加固 App 的静态结论不可信（有反调试/混淆干扰），而相机是有线上的、可观察的真实端点，抓包成本最低且结论最可靠。
替代方案：纯静态逆向（放弃）——工作量数倍且结论仍需动态验证；或直接引用社区已有 Osmo 协议资料（作为线索收集，不作依据，仍需抓包复核版本差异）。

### D2. iOS 架构：协议层/会话层/渲染层/UI 四层分离
```
┌─ UI (SwiftUI)  ControlScreenView … 按 IMG_1926.PNG 布局
├─ Session  CameraSession(Actor)：连接生命周期、心跳、重连、遥测缓存
├─ Protocol MimoProtocol：帧编解码、命令封装（纯函数，可单测）
└─ Transport Network.framework(NWConnection TCP/UDP) + NEHotspotConfiguration(入网辅助)
     └─ Video VideoToolbox 解码 → PixelBuffer → Metal/SwiftUI 展示
```
- **协议层纯 Swift struct/enum + Codable 风格编解码**，与传输解耦：协议文档 ↔ 代码一一对应，Android 后续可平行实现。
- **CameraSession 用 Swift Actor**：单入口管理连接状态机（`idle → joining → handshaking → connected → reconnecting`），UI 通过 AsyncStream 订阅状态与遥测，避免回调地狱与数据竞争。
- **视频管线**：UDP 收包 → 按协议文档解封装出 H.264/H.265 NALU → `VTDecompressionSession` 硬解 → `CVPixelBuffer` → `VideoDisplayView`（Metal layer）。直接用 Metal 兜底而不用 `AVSampleBufferDisplayLayer` 的原因：后者对自组包的裸流时间戳/格式描述较挑剔，调试黑盒；若实测够用则优先换回 AVSampleBufferDisplayLayer（少写解码器胶水）。
- **入网**：`NEHotspotConfiguration`（需 Network Extension entitlement）自动加入相机热点；同时保留"手动去设置里连 Wi-Fi"的降级路径（企业签名/个人证书侧载下 entitlement 受限时仍可用）。

### D3. 模式/命令建模：以枚举+参数表驱动 UI
六种拍摄模式（运动延时/延时摄影/慢动作/视频/照片/直播）建模为 `ShootingMode` 枚举，每种模式绑定：快门语义（录制 start/stop 或拍照）、可用设置项、图标。UI 不写模式 if-else，新增模式只改枚举与参数表。命令失败以协议确认超时/NACK 统一处理为 `CommandError`。

### D-ctrl. 控制命令层：OSMO datalink 单发应答 + ACTION4 参数表（2026-11-07 修订）

**背景**：协议路线已定案为 osmocam datalink（[osmocam](https://github.com/luisreysan/osmocam)、
[osmo-client](https://github.com/luisreysan/osmo-client)、[osmosis](https://github.com/KonradIT/osmosis)
三开源仓库互证，OA4 真机 30fps 预览 + 状态全量上线），控制命令全集以 osmo-client
`camlink/camera.py`（OA4 已验证）为基线，替代早期"仅从 Mimo pcap 猜命令"的路线。

**决策**：
1. 控制命令走 OSMOCameraLink data packet 通道（命令集 `0x02` → receiver `0x01`），
   **单发等应答**（同一时刻至多一条在途，osmocam §5.9），应答首字节结果码统一映射
   `CommandError`（00 成功 / E0 不支持 / E3 参数或状态非法 / DF 当前不可用 / D8 存储不可用）。
2. OA4 不发布 `camcap_*` 能力主题（全部应答 01）→ 每模式值域硬编码为 ACTION4 参数表
   （取自 osmo-client camera.py ACTION4_FORMATS，测试者真机逐项验证），UI 由表驱动。
3. 每个拍摄模式独立记忆曝光/格式参数 → 模式切换 02/E1 成功后延迟重查（链接层
   `onCaptureModeChanged` 钩子已实现）；周期设置回读循环保持与相机端改动同步。
4. 格式/参数变更会重启相机编码器（预览暂停 2-5s）→ 设 `video_grace` 宽限窗口，
   期间不把预览中断误判为流故障（慢动作/格式切换最长 12s）。
5. 录制启停按模式分派：视频/夜景/慢动作/运动延时 `02/02`，延时摄影 `02/01`
   （`02/02` 在延时下答 DF，osmo-client record_command 同款）；录制状态以 02/80 推送为准。
6. 变焦（02/B8）与云台（04/xx）为 Pocket 系列专用，OA4 不实现；Mimo 官方 App 对 OA4
   有数字变焦（旧 pcap 抓到 1.0→2.0→1.5x）但其命令未定案，列为后续受控抓包实验项，
   现阶段展示 FOV（02/8E 参数 0x0009）替代。

**否决**：把 `camcap_*` 能力表解析做成通用引擎——OA4 无此主题（YAGNI）；
OSMOStatusTracker 的未知主题解析位保留，未来机型接入时可用。

### D4. 逆向中间产物不入库
脱壳 dex、反编译源码、抓包 pcap 存放于本机临时目录（如 `/tmp/mimo-re/`）；入库的只有提炼后的协议文档与（脱敏后的）样例帧十六进制片段。

### D-update. 连接流程重实现：线性 ConnectionFlow + StepLogger（2026-10-27 修订）

**背景**：原实现为自动循环重试（scanLoop 轮询扫描 + apply×N + BLE 轮询重连），真机验证表明：
自动循环在热点未广播时无意义且产生大量无效弹窗；多路并行尝试使故障不可定位；
PacketLogger HCI 抓包已实证 Mimo 真实流程为**线性双阶段**（BLE 唤醒 → WiFi 入网+凭据查询）。

**决策**：
1. **废弃** `CameraWifiJoiner.scanLoop` 自动循环、BLE 轮询重连、apply 失败自动重试。
   改为 `ConnectionFlow` 线性状态机（2026-10-28 真机验证定稿）：
   `idle → waking（唤醒广播）→ querying（BLE 明文 DUML 凭据获取）→ joining（热点入网，用 BLE 凭据）→ querying（WMS 查询确认密码）→ connecting（建立会话）→ connected`，
   任一步骤失败即停在失败态，由用户点击「重试」重新执行完整流程。
2. **StepLogger 组件**：连接流程每步指令经 StepLogger 落日志，格式固定为
   `时间戳 | 步骤名 | 目的 | 内容`。内容必须包含广播命令参数、应答帧 hex、热点名与密码明文。
   StepLogger 复用 AppDiagnostics 的 UI 面板与复制通道，前缀 `[step]`。
3. **WiFi 凭据获取**（pklg 实证 2026-10-27）：入网后经 UDP 9004 向节点 07 依次发
   握手(00,2b)→扫频(00,4f)→TOKEN(40,07,45)→get_ssid(07,07)→get_password(07,0e)；
   get_password 应答为**明文密码**（无 ECDH 加密）。TOKEN 为持久化值（App 本地缓存，抓包已验证有效）。
   **修订（2026-10-28 真机验证）**：凭据**主通道实为 BLE**——连接 FFF5 后连发明文 DUML 8 帧序
   （无 R 认证、无 ECDH，dst=握手 F0/TOKEN·凭据 07/配置 88/订阅·查询 08），凭据明文应答
   `[ret:1][len:1][UTF-8]`，用于入网；入网后的 WMS UDP 查询作为确认与持久化兜底
   （密码落地后断线重连不再依赖 BLE）。
4. **BLE 唤醒广播**：官方 Demo 格式 `[len=10][0xFF]"WKP"+MAC反序]`，2.5s×N 轮；
   MAC 从相机 BLE 广播 manufacturer data 尾 6 字节解析。
5. 会话中断（已连接后的链路失效）仍保留自动重连；**仅启动连接流程**去掉自动循环——
   两者语义不同：前者是已建立会话的恢复，后者是从零开始的接入尝试。

**替代方案（否决）**：保留循环但加退避——否决理由：热点未广播时循环无法推进任何步骤，
仅刷弹窗与日志；按钮重试使失败状态可见、可定位。


## Risks / Trade-offs

- **[协议加密/带认证]** 控制帧可能带签名或会话密钥协商 → 握手密钥交换逻辑在 Native 层可静态定位；必要时用 Frida hook `libdjisdk_jni.so` 的收发函数拿明文对照。若最终存在无法绕过的设备绑定认证，文档如实记录并以"配对流程复现"为交付边界。
- **[视频流为私有封装]** 可能是 DJI 自有封装而非标准 RTP/TS → 以抓包样本逐字节分析封装头；保留解封装器接口，封装格式作为协议文档附录。
- **[iOS 后台/网络限制]** iOS 对 hotspot 配置与本地网络访问有权限弹窗与限制 → Info.plist 显式声明 NSLocalNetworkUsageDescription、Bonjour 服务；UI 引导首次授权。
- **[单机型验证]** 协议字段可能因相机型号/固件而异 → 协议文档标注"实测固件版本"，字段表留 optional 扩展位；detect 到未知固件时按文档流程回归。
- **[Flutter 层分析收益不确定]** 远程控制页也可能是 Native UI 而非 Flutter → blutter 分析定位不到时直接转向 Native/Java 线索与抓包，不强行还原全部 Dart 代码。
- **[工作量集中在协议破解]** UI/解码工程量可控，协议不确定项可能反复 → 任务按"协议文档先验收（抓包证据），再写实现"的顺序组织，未定案前不写实现代码，避免返工。

## Open Questions

（无。直播模式与相机回放/文件下载已由用户确认为非目标，见 Non-Goals。）
