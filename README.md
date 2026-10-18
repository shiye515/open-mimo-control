# OpenMimoControl

开源的 DJI Osmo Action 系列远程控制应用（iOS / SwiftUI），对标官方 DJI Mimo 的核心体验：蓝牙自动唤醒接入、H.265 低延迟实时预览、完整拍摄控制与素材浏览下载。

> 本项目为个人互操作研究，与 DJI 无任何关联；仅用于控制用户自有的相机设备。

## 功能特性

**连接（全自动）**
- 蓝牙唤醒广播（WKP + 相机 MAC）→ BLE 明文 DUML 帧序获取热点名与密码
- NEHotspot 自动入网热点 → WMS 查询确认并持久化凭据（断线重连不再依赖 BLE）
- 三步进度可视化：唤醒广播 → 热点入网 → 建立会话，步骤日志可复制导出

**实时预览**
- H.265 (HEVC) 硬解渲染，首帧秒级出图，端到端延迟可支撑取景构图
- 16:9 预览窗，16:9 码流满窗显示；预览方向跟随相机旋转；流异常自愈，无需重建会话

**拍摄控制**
- 拍照 / 录制（含延时间隔拍摄、运动延时、慢动作、超级夜景）
- 数码变焦 1.0x–4.0x（滚轮 + 捏合手势，整数焦段磁吸与触觉反馈）
- 曝光模式 / ISO / 快门 / EV / 白平衡 / 色彩档位 / 锐度 / 降噪 / 视角 / 防抖 / 分辨率帧率 / 照片比例 / 延时参数——全量设置，每项「设置 → 应答 → 回读校准」
- 相机端改动 3 秒内同步到手机（参数轮询 + 状态主题订阅）

**素材浏览**
- 相机 SD 卡文件列表分页查询（最新页 + 游标翻页）
- 缩略图加载、原文件下载（Range 断点续传）、保存到系统相册、远端删除（需确认）

## iOS 工程

```
ios/
├── OpenMimoControl/              # 应用（SwiftUI，iOS 17+）
│   ├── ContentView.swift         #   顶层路由：连接页 ↔ 控制页 ↔ 素材页
│   ├── ConnectionFlow.swift      #   连接流程状态机（BLE→入网→WMS→datalink）
│   ├── CameraWifiJoiner.swift    #   热点入网（NEHotspot + Keychain 凭据）
│   └── Screens/
│       ├── ConnectScreenView.swift    # 连接页：权限申请、进度三态、步骤日志
│       ├── ControlScreenView.swift    # 控制页：预览/参数平铺/变焦/录制
│       ├── MediaBrowseView.swift      # 素材页：缩略图网格、详情、下载/删除
│       ├── MediaLibraryModel.swift    # 素材数据编排（清单/缩略图/下载）
│       ├── LivePreviewView.swift      # 实时预览渲染容器
│       ├── Components.swift           # 通用组件（REC 角标、轮盘、轻提示）
│       └── DesignTokens.swift         # 设计令牌（深色主题色板）
│
└── OpenMimoProtocol/             # 协议 Swift Package（无 UI 依赖，可独立复用）
    └── Sources/OpenMimoProtocol/
        ├── OSMOCameraLink.swift  #   datalink：UDP 9004 帧序、握手、心跳、命令收发
        ├── OSMOControl.swift     #   拍摄控制命令（模式/录制/曝光/变焦…+ OA4 参数表）
        ├── OSMOStatus.swift      #   状态订阅与解析（02/80、主题推送→快照）
        ├── OSMOMedia.swift       #   素材协议：清单解析、00/26 查询、删除载荷
        ├── OSMOMediaSession.swift#   素材会话：分页/缩略图/下载/删除编排
        ├── OSMOVideoRenderer.swift    # H.265 AnnexB → AVSampleBufferDisplayLayer
        ├── CameraBleWake.swift   #   蓝牙唤醒广播与凭据获取
        └── …                     #   WMS 查询、SRTP 解密、RTP 重组等
```

- **OpenMimoProtocol** 为独立 Swift Package：所有 DJI 私有协议编解码都在这里，单元测试覆盖（60+ 用例，含真机抓包 golden 样本），不依赖任何 UI
- **OpenMimoControl** 仅做 UI 与编排；界面按设计稿 `docs/design/ui-design-preview.html` 实现（深色三页布局）
- 工程使用 Xcode 的文件系统同步组（`PBXFileSystemSynchronizedRootGroup`），新增文件无需改 pbxproj

## 快速开始

1. Xcode 打开 `ios/OpenMimoControl.xcodeproj`（Xcode 16+，iOS 17+ 真机）
2. 配置开发者签名（Signing & Capabilities → Team）
3. 运行到 iPhone，按引导逐项授权（本地网络 / 蓝牙 / 定位）
4. 相机开机 → 点击「连接相机」→ 全自动接入后进入控制页

## 协议文档

所有 DJI 私有协议的逆向结论沉淀在 [`docs/protocol/`](docs/protocol/README.md)，与实现行为一致、含可信度标注：

| 文档 | 内容 |
| --- | --- |
| [discovery.md](docs/protocol/discovery.md) | 相机网络发现：AP、IP 分配、端口角色 |
| [connection-implementation.md](docs/protocol/connection-implementation.md) | 已验证连接链路：唤醒广播 → BLE DUML → 入网 → WMS 查询 |
| [control-channel.md](docs/protocol/control-channel.md) | 控制通道：DUML 帧格式、CRC、握手、命令表、数码变焦与视角码表 |
| [live-view.md](docs/protocol/live-view.md) | 实时预览流：传输、封装、加密现状 |
| [telemetry.md](docs/protocol/telemetry.md) | 状态遥测：订阅机制、主题清单、值结构 |
| [media-files.md](docs/protocol/media-files.md) | 素材协议：媒体模式、文件清单、缩略图、下载、删除 |
| [tools/](docs/protocol/tools/) | 抓包解析脚本等辅助工具 |

## 参考开源项目

本项目的协议分析与实现与以下开源项目相互印证（感谢这些先行者的逆向工作）：

| 项目 | 说明 |
| --- | --- |
| [luisreysan/osmo-client](https://github.com/luisreysan/osmo-client) | Python 版 Osmo 控制客户端：命令集、变焦编码（`02/B8` 方向+速率）、模型参数表 |
| [luisreysan/osmocam](https://github.com/luisreysan/osmocam) | OsmoCam：DUML 协议文档（PROTOCOL.md）、连接与控制全流程、多机型实测 |
| [KonradIT/osmosis](https://github.com/KonradIT/osmosis) | Osmosis：Android 实现 + MEDIA_PROTOCOL.md（素材清单/下载协议权威出处） |

## 路线图

- [ ] Android 端（协议层可复用 `docs/protocol/` 移植）
- [ ] 素材批量下载 / RAW (.DNG) 支持

## 许可

未定。协议逆向仅描述行为事实（端口、帧结构、命令语义），不含 DJI 任何代码、密钥材料或受版权保护的资源，用于用户自有设备的互操作——使用风险自负。
