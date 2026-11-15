# Proposal

## Why

`docs/protocol/` 是三轮逆向的过程积累：同一主题散落多份文档，混杂"已证实 / 推定 / 未定 /
更正记录 / 代码引用"五种可信度层级，且早期误读的更正以追加方式留存。开发者无法从中
安全地提取实现依据——哪些帧格式可以直接编码、哪些 cmd 已验证、哪些值表是实测的，需要
通读全部更正记录才能判断。协议事实已经双源闭环（iOS 实测 + Android 官方 app 抓包
4131 帧 CRC 全量互证），具备沉淀为权威实现指南的条件。

## What Changes

- **目录重组**：`docs/protocol/` 整体重命名为 `docs/protocol-raw/`（逆向过程档案：
  含推定、更正记录、代码引用，仅供溯源，不再是实现依据）
- **新建 `docs/protocol/`**：面向应用开发者的协议实现指南，只包含已证实内容：
  - 总览与连接时序（ASCII/mermaid 图表）
  - 发现与配对（BLE 唤醒广播、凭据交换、热点入网）
  - 传输层（UDP 9004 外层封装的平台差异、TCP 7001 心跳）
  - DUML 帧格式与 CRC 算法（含参考实现与已验证测试向量）
  - 命令参考（模式切换/拍照/录像/快门/EV/ISO/白平衡/FOV/变焦/倒计时/订阅/对时/保活）
  - 遥测主题参考（订阅机制、已实锤的推送值结构）
  - 平台差异附录（iOS / Android 官方 app 行为差异）
- `samples/`（样例帧 fixture）与 `tools/`（CRC 校验、pcap 解析、OTP 计算等脚本）
  保留在新 `docs/protocol/` 下作为实现配套资源
- 未证实内容（推定/未定项）不进入新文档，仅在 `protocol-raw/` 中可查

## Capabilities

### New Capabilities

- 无（纯文档重组，`skip_specs: true`；协议事实作为 spec 的形式化留待后续变更）

### Modified Capabilities

- 无

## Impact

- `docs/` 目录结构变化（protocol → protocol-raw + 新 protocol）
- 无代码影响；`docs/protocol/tools/` 脚本路径变更需同步文档内引用
- 隐私规范维持：设备标识（MAC/SN/密码/相机名后缀）以 `**` 脱敏，pcap 不入库
