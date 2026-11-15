# Design

## Context

协议事实已经双源闭环：iOS 官方 Mimo 抓包（mimo-ios.pcap，2026-10-19）+ Android 官方 app
抓包（2026-11-14/15，两轮，4131 帧 CRC 互证）+ APK native 层符号/反编译
（`DjiProtocolEncoder::Encode`）。素材分散在 docs/protocol/ 的 14 份过程文档中，
可信度层级混杂。素材清单：

- 已证实：DUML 帧格式与 CRC（双向 4131 帧校验）、UDP 9004 外层（两平台）、TCP 7001、
  模式切换/拍照/录像/快门/EV/ISO/白平衡/FOV/变焦/倒计时/Pro/EIS/弱光/ISO MAX/朝向、
  订阅（00/99，21 key）、对时（00/4A）、事件（00/76）、保活节奏、20 主题推送（8+ 主题值结构实锤）
- 未证实（排除出新文档）：ACK 块编码、帧率码 4=48fps、未知 pid 000A/0015/0018/0020/0028/0029/001F
  的语义、cam_fov 推送值语义、直播模式、CSDK 加密日志

## Goals / Non-Goals

**Goals**

- 新 `docs/protocol/`：只含已证实内容，面向"从零实现远程控制 app"的开发者，
  按实现顺序可读；图表用 ASCII art（GitHub 渲染友好），时序用 mermaid `sequenceDiagram`
- `docs/protocol-raw/` 归档全部过程文档（推定/更正/未定项），作为唯一溯源处
- 正文溯源链：每份新文档末尾"证据"节链接到 protocol-raw 对应文档与 pcap
- 隐私规范继承（设备标识 `**` 脱敏、pcap 不入库）

**Non-Goals**

- 不新增协议实验（未证实项保持未证实，标注"待验证"指向 raw）
- 不改 iOS 代码；不改 openspec specs（协议事实形式化留待后续变更）
- 不迁移 `docs/protocol/captures/`（app-logs/pcap 已被 .gitignore 排除，随 raw 归档）

## Decisions

1. **目录布局**：`protocol-raw/` = 14 份过程文档 + data/ + captures/；`protocol/` =
   8 份新文档 + samples/ + tools/（fixture 与脚本是实现资源，随新文档走）。
   老文档内相对互链在 raw 内部仍然有效，无需改写。
2. **可信度甄别规则**（进入新文档的硬门槛，满足其一）：
   真机写入验证成功；抓包命令→状态推送对证（≤0.4s）；CRC 可校验的样例帧；
   双源（iOS/Android）一致。推定/未验证来源/单次观测无对照 → 不进正文。
3. **文档结构**（8 份，实现者阅读序 = 依赖序）：
   `README.md`（全景+路线）→ `discovery-pairing.md` → `transport.md` →
   `duml-frame.md` → `commands.md` → `telemetry.md` → `keepalive-timing.md` →
   `platform-notes.md`
4. **图表**：帧布局/头布局/TLV 结构用 ASCII 盒图（字段对齐最清晰）；
   连接时序与状态机用 mermaid（`sequenceDiagram`/`stateDiagram-v2`，GitHub 原生渲染）；
   保活节奏用 ASCII 时间轴。
5. **cmd 记法**：统一用 DUML 三元组 `cmdSet/cmdId`（如 `02/28`），不使用本轮误读的
   u16 形态；cmdType 单列表述。
6. **快门/EV/ISO 编码以双源一致值为准**：快门 `0x8000|分母`+小数字节、EV 码 16 基准
   1/3 档、ISO `log2(ISO/50)+1`——三者在 iOS 文档与 Android 实测中一致或互补，
   Android 单点推定的部分（EV 0.0=16）标注"推定：单点"并保留公式。

## Open Questions

无。
