# Proposal

## Why

现有 iOS 界面（连接页 + 控制页）是调试期堆叠布局：控制页用 ScrollView 平铺遥测网格、3×2 模式栏、详情面板，信息密度和操作路径都不符合产品形态。设计稿 `docs/design/ui-design-preview.html` 已确定三个主界面的最终布局与交互（连接、控制、素材浏览），需要按它重构界面。

## What Changes

- **连接页重构**：改为设计稿三态布局 —— 应用标识 + 权限行（本地网络/蓝牙/定位，逐项「申请/已授权」）+ 进度卡（百分比、当前步骤、失败原因）+ 底部大按钮（待连接 / 连接中禁用 / 已连接自动进入）。失败时进度卡显示失败步骤与原因，保留重试按钮。
- **控制页重构**：
  - 顶部状态两行：电量·温度、SD 容量（第一行）；分辨率/帧率、FOV、曝光（第二行）。不再展示录制时长（移至预览左上角 REC 角标）与录制模式徽标。
  - 实时预览为固定高度圆角预览区，左上角仅 REC 角标。
  - 拍摄参数去掉「拍摄参数设置」折叠标题，直接平铺全部参数项，占满预览与底部按钮之间的区域，超出在面板内滚动；每项仍走「设置 → 相机应答 → 回读校准」。
  - 底部操作栏固定页面底部：左侧素材浏览图标按钮、中央快门（录制红色圆 / 录制中方块 / 拍照白圆）、右侧录制模式图标按钮（图标跟随当前模式）。
  - 模式选择由底部 3×2 模式栏改为底部弹窗（六模式，当前模式高亮，直播项保留未实现提示）。
- **新增素材浏览页**：按设计稿搭出页面外壳（左上角返回、SD 剩余、3 列缩略图网格）；素材列表协议尚未实现，本期只提供空态展示与导航结构。
- **路由扩展**：`ContentView` 从两页路由（connect ↔ control）扩展为三页（connect ↔ control ↔ media），并按界面拆分视图文件。
- **BREAKING**：界面视觉从系统默认亮色改为设计稿深色风格；控制页不再展示「相机状态详情」折叠面板、变焦提示与断开按钮的旧位置（断开入口移入连接页/状态区）。

## Capabilities

### New Capabilities

- `media-browse`: 素材浏览页外壳 —— 从控制页进入、SD 剩余展示、缩略图网格布局与空态、返回导航；素材文件列表协议本期不接入。

### Modified Capabilities

- `control-screen`: 「主界面布局」要求整体替换为设计稿布局（固定预览区 + 顶部两行状态 + 平铺参数面板 + 底部三键操作栏）；「模式切换」的入口从底部模式栏改为模式底部弹窗。
- `camera-connection`: 新增连接页界面要求（三态布局、权限行逐项申请/已授权、进度卡、底部大按钮、失败态）；连接流程协议要求不变。
- `live-view`: 实时画面渲染区域从「全屏预览」改为控制页固定高度预览区；构图网格线开关不再提供界面入口（从要求中移除）。

## Impact

- 代码：`ios/OpenMimoControl/ContentView.swift`（900 行单文件拆分）—— 新增 `ConnectScreenView`（重构现有 ConnectView）、`ControlScreenView`（布局重构，复用 ConnectionFlow/OSMO 命令层与设置面板数据）、`MediaBrowseView`（新建）、`AppRoute` 扩展 media。
- 不改动：连接流程（ConnectionFlow/CameraWifiJoiner）、OSMO datalink 命令与参数表（OSMOA4）、视频流管线（LivePreviewView 渲染层复用，仅容器布局变化）。
- 规格影响：`openspec/specs/control-screen`、`openspec/specs/camera-connection`、`openspec/specs/live-view` 出现增量；新增 `openspec/specs/media-browse`。
- 设计基准：`docs/design/ui-design-preview.html`（含 ①—⑧ 八个状态图）。
