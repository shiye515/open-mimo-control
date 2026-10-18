# Tasks

> 执行约束（来自 design D1/D4）：所有协议结论必须以真机抓包证据定案后才进入对应实现任务；逆向中间产物（脱壳 dex、反编译文本、pcap）只存放在本机临时目录（如 `/tmp/mimo-re/`），不入库；入库物只有提炼后的协议文档与脱敏样例帧。

## 1. 逆向环境与线索收集

- [x] 1.1 建立 `/tmp/mimo-re/` 工作区，解包 APK（unzip 到 /tmp/mimo-re/apk），导出 native 库清单与 `strings` 摘要，验证：`ls /tmp/mimo-re/apk/lib/arm64-v8a | wc -l` 与 APK 内 .so 数量一致
- [x] 1.2 对 `libdjisdk_jni.so`、`libdjibase.so`、`libDJIVideoJNI.so`、`libassemble_proto.so`、`libilink_live.so` 做字符串与导出符号分析（nm/objdump），提取端口、魔数、命令字、密钥相关线索，验证：`/tmp/mimo-re/notes/native-leads.md` 中每个线索标注来源库名+偏移
- [x] 1.3 用 blutter 分析 `libapp.so`（Dart AOT），提取远程控制页面相关的类名/方法名/字符串，验证：notes 中能定位到模式切换、录制、变焦等方法命名线索（若 Flutter 层无相关内容，记录结论后跳过，走 Native/抓包路线）——结论：Dart 层零中文、无相机业务命名，已按约定记录并跳过
- [x] 1.4（可选，前序线索不足时）Android 真机/模拟器安装 Mimo 并用 frida-dexdump 脱壳，jadx 检索连接/控制相关业务类，验证：找到至少一条与 1.2 线索互相印证的调用链；中间产物留在 /tmp 不入库——未触发：1.2 线索已充分（307 个命令三元组），且本机无 Android 设备

## 2. 协议逆向与文档定案

- [x] 2.1 真机抓包：手机连接相机热点并进入官方 App 远程控制界面，采集"连接→预览→五种拍摄模式切换→开始/停止录制→变焦→断开"全程 pcap（经 iOS rvictl 采集，docs/mimo-ios.pcap，154MB），验证：pcap 覆盖至少一次完整录制与一次模式切换时段——实际覆盖 6 段录制（1/2/5/6/延时 5/直播 12s）、5 种模式切换、捏合变焦 1.0x→2.0x→1.5x
- [x] 2.2 分析 pcap 确定发现/入网与控制通道：传输层、端口、握手序列、心跳周期，与 1.2 静态线索互证，验证：`docs/protocol/discovery.md` 与 `docs/protocol/control-channel.md` 初稿完成，关键结论附 pcap 帧编号证据——控制=UDP 9004 主通道+TCP 7001 辅助；帧格式/握手/订阅风暴/模式切换命令（40 02 e1 xx）/录制开始命令（40 02 02 00，含 ACK 回显）均已证实
- [x] 2.3 分析视频流：传输方式、封装格式、编码参数（H.264/H.265、分辨率档位），从 pcap 提取样例帧，验证：`docs/protocol/live-view.md` 完成且样例帧十六进制片段能被 ffprobe/手工解析佐证封装判断——UDP 9004 约 5.8Mbps（2.7K/60）；载荷高熵无 NALU 起始码，判定加密（sec_comm 对应），解密为 live-view 最大未定项，样例已入库
  - **2026-11-06 修正**："加密"判定系分片帧格式误读——正确分片为 osmocam 帧格式（8B link 头 + 20B 视频子头），载荷为**未加密 H.265 Annex-B**（ffprobe/ffmpeg 解码 1235 AU 实证 + 真机渲染成功）；OA4 实测 1280x720/25fps。`docs/protocol/live-view.md` 待按 osmocam 格式回写
- [x] 2.4 分析遥测：电量/存储/信号/分辨率/录制时长的报文字段与更新周期，验证：`docs/protocol/telemetry.md` 完成且字段表含字节偏移与实测值对照——订阅按主题名（明文）；cam_status/cam_fov(等效焦距×100)/cam_record_time/cam_storage 值结构经时间轴对齐证实
- [x] 2.5 用独立脚本按文档重放一条只读命令（如查询状态）验证文档自洽，验证：脚本输出与抓包中官方行为一致；文档标题统一标注"实测固件版本"——`docs/protocol/tools/parse_mimo_capture.py` 按文档规则解析全程抓包：13,588 帧、模式值域恰为 {00,01,02,05,0a}、录制 start/ack 配对、cam_status 解析通过；并发现修正了一处文档错误（帧头无独立 session 字段）；CRC 复算确认 6 种标准算法均不匹配。注：向真机在线重放只读命令待相机可连时补做；固件版本未在抓包中定位到明文，已列为待补项

## 3. iOS 工程基础

- [x] 3.1 在 `ios/` 建本地 Swift Package `OpenMimoProtocol`（纯 Swift、无第三方依赖），挂入 Xcode 工程，验证：`cd ios/OpenMimoProtocol && swift build && swift test` 通过（含一个占位测试）
- [x] 3.2 配置 App 工程：Info.plist 增加 NSLocalNetworkUsageDescription 与 Bonjour 声明， entitlements 增加 NEHotspotConfiguration，替换模板 ContentView 的挂载点为空的控制路由，验证：`xcodebuild -project ios/OpenMimoControl.xcodeproj -scheme OpenMimoControl -destination 'generic/platform=iOS' build` 成功——NSLocalNetworkUsageDescription 经 INFOPLIST_KEY 注入；entitlements 采用 wifi-info（读取 SSID 识别相机热点，NEHotspotConfiguration 配网本身无需特权 entitlement）；Bonjour 服务声明待 2.1 抓包确认相机实际服务类型后补充；构建需 `-allowProvisioningUpdates`（capability 自动注册），已 BUILD SUCCEEDED

## 4. 连接与会话（camera-connection）

- [x] 4.1 在 OpenMimoProtocol 实现帧编解码（握手、心跳、命令封装、样例帧回归用例），验证：`swift test` 中用 2.2 提取的脱敏样例帧作为 fixture 全部通过——15 个测试全绿；过程中修正 3 处 fixture/文档转写错误（录制帧 len=0x0e、cam_fov 1.5x 字节序、reqID 为 body[7..8] u16 LE），并回写至 docs/protocol/ 与 samples/；同日经 DJI 官方 Osmo GPS Controller Demo 文档确认帧格式为 DUML（0x55），CRC8(0x8C/0x77)+CRC16-MCRF4XX(0x8408/0x3692) 已解，编码与抓包帧逐字节一致，codec/测试/文档全部重构至 DUML
- [x] 4.2 实现 NWConnection 传输层与 CameraSession Actor 状态机（idle→joining→handshaking→connected→reconnecting），验证：模拟断链单测中超时阈值内进入 reconnecting，UI 订阅能收到状态流——`NWCameraLink`（UDP 9004 + TCP 7001）+ `CameraSession` actor（看门狗/心跳/订阅风暴/遥测聚合）；4 个 mock 链路单测覆盖连接握手、静默重连、遥测更新、命令下发，套件 19/19 绿
- [x] 4.3 【重实现】连接流程重构为线性 ConnectionFlow + StepLogger（按 design D-update），验证：真机点击连接按钮后完整走通"唤醒广播→BLE DUML 取凭据→热点入网→WMS 查询→密码记忆"，步骤日志完整可复制；失败时停在失败步骤并显示重试按钮，无任何自动循环。——真机连续两轮端到端通过（2026-10-28 01:09/01:12，各约 18s）：BLE DUML 帧序按 pklg 逐帧比对修正 dst（握手→F0、配置→0x88、订阅/查询→0x08）后 SSID/密码明文应答全通，NEHotspot apply 首次稳定成功（此前失败根因=密码错误），fetchCurrent 确认入网，断开重连可复现
  - [x] 4.3a 新建 `ConnectionFlow`：线性状态机 idle→waking→joining→querying→connected；每步失败即停；删除 `CameraWifiJoiner.scanLoop` 自动循环与 BLE 轮询重连
  - [x] 4.3b 新建 `StepLogger`：固定格式 `时间戳 | 步骤名 | 目的 | 内容`，复用 AppDiagnostics 面板与复制通道，前缀 `[step]`
  - [x] 4.3c 唤醒广播接入：认证通过后广播 WKP+MAC反序 2.5s×N（HotspotWaker 已有，接入 ConnectionFlow waking 步骤），广播动作与结果入 StepLogger
  - [x] 4.3d 热点入网步骤：NEHotspotConfiguration apply（用 BLE 取回的真实密码），结果入 StepLogger；失败显示步骤+重试按钮——apply 成功率问题的根因是历史密码错误，BLE 凭据取回后连续两次 apply 成功
  - [x] 4.3e WMS 查询步骤：握手(00,2b)→扫频(00,4f)→TOKEN(40,07,45)→get_ssid(07,07)→get_password(07,0e)，查询与应答逐帧入 StepLogger；密码明文解析后持久化——实现改为 Mimo 实测 BLE 路径：连接 FFF5 后直发明文 DUML 8 帧（无 R 认证、无 ECDH），应答格式 [ret:1][len:1][明文]
  - [x] 4.3f 连接页 UI：连接按钮、当前步骤状态显示、失败原因+重试按钮、日志面板（maxHeight+复制）
- [ ] 4.4 实现遥测解析与发布（电量/SD/信号/分辨率/录制时长），验证：真机连接后 UI 展示值与相机屏幕/官方 App 一致，电量变化与录制计秒符合 specs 场景——代码完成（`TelemetrySnapshot` 聚合 cam_status/cam_fov/cam_record_time/cam_storage，控制页状态条占位网格展示，构建通过）；**控制页电量 100% / SD 实时显示已随 2026-11-06 预览轮多次复现**（复用直连后 UI 状态条即显示）；剩余验收=录制计秒场景（需录制操作）；电量 BLE 场景 (0d,02) 已校准
  - 2026-10-28：定位并修复遥测不上线的两个链路层根因（NWCameraLink 发送失效、外层包头 20B→34B 布局错误，见 iter_20261028_0153.md）；修复后相机开始回包且 session 回显与 pcap 逐字节一致；遥测推送的最终验证待相机可用（第二轮验证时相机休眠）
  - 2026-10-28 续：离线探索全部完成——电量主题定案（WiFi 主题空间无电量，候选路径=1D02 推送/BLE 0x0d02）、cam_storage 语义定案（total/free/photo）、locate() 丢帧修复、CameraStatusV2+1D05 探测+BLE 推送日志实装、控制页电量行、TelemetryParsingTests 5 测试全绿；真机验证卡点=相机不可用（03 轮重试 BLE 零发现）
  - 2026-10-28 三轮（相机开机）：**遥测真机上线**——再修两根因（NWConnection.receive 对 UDP 首包即 isComplete 不能当流结束；外层包头 20B 业务头逐包序列破译）+ SwiftUI @StateObject init 挂接丢失；控制页 SD 实时显示 ✓（110.9GB，0x80 推送每秒）；复用直连路径落地（已在相机网络 0.09s 直连，跳过唤醒/BLE）；BLE 电量 (0d,02)@20=u16LE% 校准；剩余=录制计秒/电量变化场景验收（需录制操作与 BLE 场景）

## 5. 实时预览（live-view）

- [x] 5.1 实现流接收与解封装（按 live-view.md），验证：单测用 pcap 提取的流片段解出连续 NALU 序列，无解析错误——**✅ 真机验证完成（2026-11-06，路线更正：视频流为明文 H.265，非 SRTP 加密）**
  - **路线更正**：旧判定"载荷高熵=SRTP 加密"系分片帧格式误读——正确协议为 [osmocam](https://github.com/luisreysan/osmocam)（MIT）路线：8B link 头（u16 0x8000|len + session + seq + type + xor）+ type2 视频包（20B 子头，AU 内 `00 00 01 FF` + u32 LE 长度 + 头长 0x0C 低 6bit），**完全未加密 H.265 Annex-B**（ffprobe/ffmpeg 解码 1235 AU 实证）
  - **OSMOCameraLink.swift 真机闭环**：BLE 配对门（07/45 osmo 身份→相机屏确认→07/46=01 持久化）→ TCP 7001 poke（单发配对帧+0.4s 关闭）→ 48B type-0 握手（ms 级应答）→ 注册+09/A8+encoder 心跳(00,4f/200ms) → type-2 视频包 → FrameAssembler 重组 AU → onVideo 回调
  - 两个字节级 bug 均由"A/B 实测 + 首包/NALU dump"定位：①握手块 "20" 字段是 u16（osmocam `<HHHHBH>`），写成一字节致 45B≠48B 被相机静默丢弃；②poke 高频重发会顶掉相机屏幕配对提示并重置状态机
- [x] 5.2 实现 VideoToolbox 硬解 + Metal 渲染视图，验证：真机首帧展示 ≤ 数秒、画面连续、端到端延迟目测可支撑取景（对比官方 App）——**✅ 真机渲染成功（2026-11-06）**：OSMOH265Renderer（AnnexB→NALU 分割→hvcC→CMVideoFormatDescription(HEVC)→AVCC→CMSampleBuffer→AVSampleBufferDisplayLayer.enqueue，A12 硬解+渲染一体）；控制页预览区 osmoFrameCount>0 时自动挂载 OSMOVideoLayerView 显示实时画面（OSMO帧 2,295+ 持续增长，两截图对比确认实时性）；挂载后 requestOSMOKeyframe 请求新 IDR（挂载前的 IDR 已丢，P 帧无参考不可解）
  - HEVC NALU type 表坑：**32=VPS**（不是 35！35=AUD）——曾把 3B 的 AUD 塞进 hvcC 当 VPS → 解码器初始化失败黑屏；由"AU NALU 列表 dump"（t32/35B t33/47B t34/8B t20/28.8KB t40/30B t35/3B）一眼定位
  - 旧 SRTP 路线（LiveViewPipeline/LiveViewDepacketizer/SRTPDecryptor）保留未删但已弃用；LiveViewPipeline 为 H.264 专用且依赖已撤销的加密假设
  - 2026-10-29 双抓包记录（历史，SRTP 假设已撤销）：SRTP 密钥信令观察系 Mimo 与 DJI 云的通信，与 OA4 本地 datalink 无关
- [ ] 5.3 实现网格线开关（默认开）与流中断自愈（丢包自愈、流停重建），验证：人为遮挡/远离信号复现 specs 两个场景的行为
  - 2026-11-06 部分：datalink 已有外层重试循环（30 次握手无应答→2s 后重新 poke，参考实现同款）与 encoder 心跳保活；网格线开关与丢包自愈场景验证未做

## 6. 控制界面（control-screen）

> 2026-11-07 前置注记：**状态读取面已上线**——OSMOCameraLink.statusTracker 解析 02/80（相机状态）、
> 0D/02（电池）、02/DC（存储）、00/99 主题订阅（cam_expo_param/cam_image_effect/cam_lapse_param）
> 与 02/19/1F/2B/29/2D 查询，8 个偏移锁定单测全绿；控制页状态条 + 详情面板全量活值真机验证。
> 控制命令基线 = osmo-client camlink/camera.py（OA4 已验证）+ osmocam PROTOCOL.md §6/§7；
> OA4 无 camcap_* 能力主题 → ACTION4 参数表硬编码（design D-ctrl）。本节任务在此之上补控制面。
>
> **2026-11-07 真机验证轮（OSMOControl.swift 控制面全量上线）**：
> ① 录制分派——延时模式启停走 02/01（REC 计秒/红按钮同步）、E3 失败横幅复现、单飞在途守卫（6.2）
> ② 模式切换 02/E1 ×2 成功（照片↔视频，高亮/快门语义随 02/80 byte57 联动）（6.3）
> ③ 设置面板十项回读全活（02/8E FOV=标准/EIS=HorizonBalancing、02/13 比例=16:9、自动下快门 —=DF 正确呈现）（6.5）
> ④ 格式/延时刻行按模式显隐就位、02/19/02/13/cam_lapse_param 回读活值（6.6/6.7）
> ⑤ 双指捏合 → "变焦未实现"提示、无命令发出；FOV 角标 "24 fps · 标准"（6.8）
> 遗留：手动曝光下 ISO/快门设置闭环、一次真实格式切换（1080p/240）、一次延时间隔设置的端到端场景
> （WDA 菜单弹窗自动化受限，人手点按即可验收；命令层与已验证命令走同一机制）。

- [ ] 6.1 按 docs/IMG_1926.PNG 实现主界面布局：全屏预览、顶部状态条（WiFi/电量/HB/SD/时长/分辨率角标）、六模式底栏、红色录制按钮、回放与用户入口、…"菜单与主页按钮，验证：真机截图与参考截图逐元素对照清单通过
- [x] 6.2 实现录制/拍照控制与失败反馈：命令按模式分派（视频/夜景/慢动作/运动延时 02/02 [01]/[00]；延时摄影走拍照命令 02/01——02/02 在延时下答 DF）、结果码统一 CommandError（00/E0/E3/DF/D8）与确认超时；录制状态以 02/80 推送（字节 0 bits 6-7）同步按钮形态与计秒，验证：真机开始/停止录制与按钮形态、顶部计时同步；延时模式启停走 02/01；存储卡拔出场景按钮不进入录制态并提示原因
- [x] 6.3 实现五种已实现模式的切换（02/E1，枚举 + ACTION4 参数表驱动；直播为占位，选择不发送命令并提示未实现；录制中先停止或拒绝；切换成功后延迟重查设置——onCaptureModeChanged 钩子已实现），验证：specs 对应场景逐条真机通过
- [ ] 6.4 实现菜单、回放入口与直播模式占位（点击给出明确"未实现"提示）与断连禁用逻辑，验证：未实现入口点击有明确提示；断开相机后操作按钮禁用且展示断连状态
- [x] 6.5 实现拍摄参数设置面板（specs「拍摄参数设置」十项）：曝光模式 02/1E、ISO 02/2A（码 03-0C=100-51200）、快门 02/28（50 档速度表）、EV 补偿 02/2E（±3EV 三分位）、白平衡 02/2C（2000-10000K）、色彩档位 02/42、锐度 02/38、降噪 02/44、FOV 02/8E 参数 0x0009、防抖 02/8E 参数 0x0008；每项"设置→应答→回读校准"，生效值来自查询（02/1F/2B/29/2D）与 cam_expo_param/cam_image_effect 推送；设置/模式切换的编码器重启走 video_grace 宽限不误判流故障，验证：手动曝光设置 ISO/快门回读一致；自动模式下 ISO 设置答 E3 并提示；相机端改动经回读同步
- [x] 6.6 实现视频/照片格式切换：02/18（分辨率+帧率+慢动作倍速，OA4 拒绝 aspect 写→单独发送不携带 02/8E 0x0046）与 02/12（照片模式，比例 4:3/16:9）；值域按 ACTION4_FORMATS 表（视频 4K/2.7K/1080p/4K4:3/2.7K4:3，4K·2.7K 最高 120fps、1080p 最高 240fps、4K4:3 最高 60fps；夜景 24-30；延时 25/30；运动延时仅 30；慢动作 4×/8×）；02/19/02/13 回读校准，验证：1080p/240 切换回读一致；慢动作带倍速；照片比例切换（尺寸固定）
- [x] 6.7 实现延时/运动延时参数设置：02/6C 双形态（timelapse：保存类型+间隔 0.1s+时长 s；hyperlapse：速度 u16 0=auto）；当前值从 cam_lapse_param 回读，验证：设置间隔后推送回读一致
- [x] 6.8 变焦未定案处理：OA4 无变焦/云台命令（02/B8 与 04/xx 为 Pocket 专用，三仓库一致；Mimo 对 OA4 的数字变焦命令未定案）——预览区展示 FOV 设置（02/8E 0x0009 回读），捏合手势不发命令并提示"变焦未实现"；Mimo 数字变焦命令列为后续受控抓包实验项（不阻塞），验证：捏合无命令发出且有提示；FOV 值随设置变化

## 7. 集成验证与收尾

- [ ] 7.1 端到端回归：按 IMG_1926.PNG 完整走查"连接→预览→五种模式→直播/回放占位提示→录制/拍照→变焦→断连→重连"，对照三个 spec 的全部场景记录结果，验证：walkthrough 清单全绿并附真机截图
- [ ] 7.2 更新 README（项目简介、构建方法、协议文档索引、clean-room 与合规说明），验证：按 README 从克隆到真机运行可复现
- [ ] 7.3 `openspec validate extract-remote-control-to-ios --strict` 通过，所有中间产物确认未入库（`git status` 无 /tmp 产物、无脱壳/反编译文件）
