# DJI Mimo 远程控制协议文档

本目录是对官方 DJI Mimo（Android 版 APK，见 `docs/DJI-Mimo-store-official-release-10001997_sec.apk`）
远程控制能力的**协议事实**提炼，作为 OpenMimoControl（iOS）及相关实现的唯一协议依据。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [discovery.md](discovery.md) | 相机网络发现与接入：AP、IP 分配、端口角色、探测行为 |
| [connection-implementation.md](connection-implementation.md) | **已稳定工作的连接链路实现**（2026-10-28 真机验证）：唤醒广播 → BLE 明文 DUML → NEHotspot 入网 → WMS 查询，含代码结构、帧序表、持久化键 |
| [control-channel.md](control-channel.md) | 控制通道：帧格式、握手序列、命令载体、模式切换/录制命令、心跳 |
| [live-view.md](live-view.md) | 实时预览流：传输、封装、加密现状与破解路径 |
| [telemetry.md](telemetry.md) | 状态遥测：订阅机制、主题清单、各主题值结构 |
| [topics-catalog.md](topics-catalog.md) | 00/99 命名主题总目录（20 状态主题 + camcap_* 能力主题 + 非 OA4 项）与订阅/推送机制 |
| [frame-format-android-csdk.md](frame-format-android-csdk.md) | **Android 官方 app CSDK 层帧格式（源码级）**（2026-11-14）：`DjiProtocolEncoder::Encode` 反编译，V2 帧 `0x400\|len` + CRC8（前 3 字节，含尾字节归零校验）+ CRC16-KERMIT（帧尾）分层与 iOS 侧 DUML 认知互证 |
| [cmd-map-android-csdk.md](cmd-map-android-csdk.md) | **Android 实测 cmd 路由表**（2026-11-14 抓包实证）：0x8e02 轮询、0x0101 参数设置（payload 含参数计数/ID 模式）、0x4f00/0x6102/0x4407/0x8800 周期查询组；`data/` 为 4676 模板实例常量与 121 proto 类型清单 |
| [capture-analysis-android-20261114.md](capture-analysis-android-20261114.md) | Android 抓包会话分析（** 无 root，SysDump TCP DUMP 方法论）：流量结构、操作时间线与页面事件对齐、45 个 Key 遥测字典 |

## 证据来源

- **Android 官方 app 逆向资产**（不入库的大文件，位于 `~/work/dji-research/`）：官方 APK 四分包、
  CSDK 原生库（`libdjisdk_jni.so` 等 19 个）、Ghidra 分析项目（`ghidra-proj/`，含
  `libdjisdk_jni.so`/`libdjibase.so` 两库的完整分析）与批量反编译输出（`decompiled/`）。
  复用脚本见 `ghidra_scripts/`（Ghidra 12.2 headless，安装于 `~/tools/ghidra_12.2_PUBLIC/`）。
- 抓包：`docs/protocol/mimo-ios.pcap`（iPhone 上的官方 Mimo 通过相机热点操控 Osmo 相机的全程流量，154MB，pcapng）。
  有效会话时段 **19:52:35 – 19:55:20**（手机 192.168.2.140 ↔ 相机 192.168.2.1），
  覆盖：连接、预览、模式切换（照片/视频/慢动作/延时/直播）、多次录制（1s/2s/5s/6s/12s）、捏合变焦（1.0x→2.0x→1.5x）、断开。
- 静态线索：APK native 层符号分析笔记（命令三元组、订阅代理 `united_pub_sub_agent` 等）。
- 官方参考：DJI Osmo GPS Controller Demo（docs/reference/osmo-gps-controller/，见其 PROVENANCE.md）——确认帧格式为 DUML（0x55）并给出 CRC 算法；其 BLE 传输与本项目 Wi-Fi 传输共用同一命令空间。
- 样例帧：[samples/](samples/) 目录，可直接用作实现测试的 fixture。

## 结论可信度标注约定

- **已证实**：帧结构与相机状态变化在时间轴上强相关（秒级以内），可复现。
- **推定**：多次观察一致但缺对照实验（如主题名→cmd 字节的哈希假设）。
- **未定**：有观察但无结论（如视频流加密）。CRC8/CRC16 算法已于 2026-10-19 解决（control-channel.md §1/§6）。

## 重要声明

本文档仅描述协议行为事实（端口、帧结构、命令语义），用于对用户自有设备的互操作；
不包含、也不得用于复制 DJI 的任何代码、密钥材料或受版权保护的资源。
