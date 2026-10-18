# Design

## Context

- 视觉基准：`docs/design/ui-design-preview.html`（①—⑧ 共 8 个状态图），独立 HTML + lucide 图标，深色风格（背景 `#0e0e11`、卡片 `#1c1c1e`、胶囊 `#2c2c2e`、强调 `#0a84ff`、录制红 `#ff453a`、成功绿 `#30d158`）。
- 现状：`ios/OpenMimoControl/ContentView.swift`（900 行）承载全部界面 —— `AppRoute{connect, control}` 路由、`ConnectView`（扫描+自动连接+步骤日志）、`ControlScreenView`（ScrollView 平铺预览/模式栏 3×2/设置面板/遥测网格/状态详情/断开按钮）、`LivePreviewView`。连接流程（`ConnectionFlow`/`CameraWifiJoiner`）与 OSMO 命令层（`flow.osmoCommand`、`OSMOA4` 参数表）已稳定。
- 工程使用 `PBXFileSystemSynchronizedRootGroup`，在 `ios/OpenMimoControl/` 下新增 Swift 文件无需改 pbxproj。
- 素材协议（文件列表/下载/删除）尚未实现，素材浏览页本期只有外壳。

## Goals / Non-Goals

**Goals**
- 三页路由（connect ↔ control ↔ media）与三个界面的设计稿还原（深色、布局、交互）。
- 现有协议/命令逻辑零改动地接入新界面（连接流程、录制分派、模式切换、参数读写、预览管线）。
- 视图代码按界面拆分，`ContentView.swift` 只保留路由与会话容器。

**Non-Goals**
- 素材列表/下载/删除协议实现（media-browse 仅空态外壳）。
- Android 端（目录为空，无现成 UI 可重构）。
- 新增任何相机命令；变焦、直播、回放能力。
- 设计稿之外的新功能（图标风格不必复刻 lucide，用 SF Symbols 等价物）。

## Decisions

1. **文件拆分**：`ContentView.swift` 保留 `AppRoute`（扩为 `connect/control/media` 三态）+ `AppSessionHolder` + 诊断按钮；新建 `Screens/ConnectScreenView.swift`、`Screens/ControlScreenView.swift`、`Screens/MediaBrowseView.swift`，公共小件（状态行、参数胶囊、REC 角标、模式弹窗）放 `Screens/Components.swift`。备选 NavigationStack——放弃：现有自定义路由已覆盖会话生命周期管理，三页平铺场景无需导航栈。
2. **深色主题**：`ContentView` 根视图 `.preferredColorScheme(.dark)`；设计稿色值定义为 `DesignTokens` 常量（含字阶），不用 Asset Catalog 颜色（便于和设计稿逐值对照）。
3. **控制页布局骨架**：`VStack{ 顶部状态区(fixed) ; 预览卡片(fixed 高度，按屏宽比例 ≈224/329 缩放) ; 参数面板(flex:1, 内部 ScrollView，隐藏滚动条) ; 底部操作栏(fixed, safeAreaInset 底部) }`。底部操作栏用 `safeAreaInset(edge:.bottom)` 钉底，参数面板 `ScrollView` 只滚参数——对应 spec「参数面板内部滚动、状态区与操作栏固定」。
4. **参数面板平铺**：保留现有按模式分组的 `settingRow` 数据与「设置→应答→回读」逻辑，重排为设计稿的两列胶囊网格（`LazyVGrid` 2 列）；去掉折叠头；延时/运动延时等模式专属参数行同样平铺在对应模式分组下。备选 List/Form——放弃：无法还原胶囊视觉且难嵌滚动区。
5. **模式弹窗**：SwiftUI `sheet` + `presentationDetents([.height(...)])` 底部弹窗，2 列 6 项（含直播），当前模式蓝框高亮；模式→SF Symbols 映射：视频 `video` / 拍照 `camera` / 超级夜景 `moon` / 慢动作 `tortoise.fill` / 运动延时 `gauge` / 静止延时 `timer`；底部右侧模式按钮图标与弹窗选择联动（与设计稿 ⑧ 一致）。
6. **快门三态**：沿用现有录制状态驱动——待机录制类模式：白环红心圆；录制中：红边红方块；照片模式：白实心圆（拍照成功反馈保持现状）。
7. **REC 角标**：预览卡片左上角 overlay，`st.recordState == 2` 时显示，红点闪烁（`repeatForever` opacity 动画）+ `clipSeconds` 计时；顶部遥测不再展示录制时长与模式（详见 spec MODIFIED）。
8. **素材浏览页**：独立 Screen（`MediaBrowseView`），返回回调回控制页；头部「返回图标 + 标题 + SD 剩余（`st.sdFreeMB`）」；主体 `LazyVGrid` 3 列，无数据时空态文案「素材协议尚未接入」。不引入 NavigationStack、不预置占位缩略图。
9. **连接页权限行**：蓝牙行读 `CBManager.authorization`，定位行读 `CLLocationManager.authorizationStatus`（真实可查）；本地网络权限 iOS 无公开查询 API，用派生信号：会话建立过即「已授权」，否则显示「申请」——点击触发一次本地网络探测（`NWConnection` 到 `192.168.2.1`）促使系统弹窗。「连接相机」按钮语义 = 先补申请缺失权限再 `flow.start()`（对齐设计稿①注释「点击后申请缺失权限并开始连接」）。
10. **状态详情与断开（设计稿未覆盖的缺口）**：设计稿控制页没有断开/诊断入口，但 `camera-connection` 要求用户可主动断开、排查需要诊断面板。决定：顶部状态区可点击，弹出 `.sheet` 详情（复用现有 `statusDetailPanel` 行 + 复制诊断 + 「断开连接」按钮）。这是对设计稿的最小增补，样式沿用设计语言。

## Risks / Trade-offs

- [本地网络权限状态不可查询] → 用派生信号（探测/会话建立）近似，文案不声称读到了系统内部状态；真机验证弹窗行为。
- [网格线功能移除属于回退] → spec 已记 REMOVED + 迁移说明，代码路径保留（LivePreviewView 网格层可后续恢复），git 可回滚。
- [固定高度预览在不同机型上的比例] → 预览高度按 `screenWidth × 224/329` 推导并设上限，真机核对比各尺寸。
- [模式/参数面板与相机推送竞态] → 复用既有「回读校准」逻辑，不改命令层，回归用例覆盖录制中切模式。
- [顶部详情 sheet 偏离设计稿] → 标注为设计缺口增补，验收时与用户确认形态。

## Migration Plan

1. 新建 Screens 文件并迁移现有逻辑（编译可通过、行为等价）。
2. 切换 `ContentView` 路由到新三页结构，删除旧布局代码。
3. 真机回归：连接三态、录制/拍照、模式弹窗、参数滚动、素材页导航、断开。
4. 回滚策略：单提交粒度，revert 即恢复旧单文件结构。

## Open Questions

- 顶部状态详情（断开/诊断入口）以「点击顶部状态区弹出 sheet」实现，是否认可该形态？（不改变 spec 行为，可后续调整入口样式）
- 素材浏览页空态文案与是否显示「去连接页」引导（spec 允许空态提示，文案实现时定）。
