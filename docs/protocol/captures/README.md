# 抓包目录（官方 App / 自研 App 命令分析）

本目录存放抓包脚本与使用说明。抓包产物（`*.pcap` / `*.pcapng`）体积大且含视频流，**不入库**（见 `.gitignore`）；分析结论沉淀到 `docs/protocol/*.md`。

## 前置条件

- iPhone 与 Mac **USB 连接**且已信任；手机解锁
- `rvictl`（随 macOS 自带，路径 `/Library/Apple/usr/bin/rvictl`）
- `tcpdump`（随 macOS 自带）；运行时需输入 sudo 密码（rvi 抓包走 root 权限的 BPF 设备）
- 手机已接入相机热点（OsmoAction4-xxx），或准备连接

## 抓包步骤（变焦/倒计时等待定命令）

```bash
# 1. 启动（连接好手机直接运行：自动获取 UDID、自动挂载网卡、自动开始抓包；
#    多台设备时交互选择，也可传参指定）
bash tcp-capture.sh
#    bash tcp-capture.sh <指定iPhone的UDID>

# 2. 手机上操作（抓包期间）：
#    - 先关闭 OpenMimoControl（释放相机单客户端连接）
#    - 打开 DJI Mimo → 连接相机 → 进入拍摄界面
#    - 执行待分析操作（如拍照/视频模式下捏合变焦，每步间隔 2-3 秒）

# 3. 终端 Ctrl+C 停止抓包，产物为本目录下 tcp-capture-<时间戳>.pcap
```

## 分析

DUML 帧扫描可复用 `parse_mimo_capture.py` 的 CRC 函数，或参考
`openspec/changes/media-files-protocol` 中的纯 python 扫描方法（pcapng EPB 块解析 +
`55|len|crc8|…|crc16` 帧校验）。识别未知命令的技巧：

- 按命令 `(cmdSet, cmdId)` 分组计数，找操作期间新出现/频次突增的命令
- 对可疑命令按载荷分桶，找「值随操作时间变化」的组（变焦=连续数值轨迹）
- 注意本仓库旧抓包 `mimo-ios.pcap` 的会话 IP 是 `192.168.2.233 ↔ 192.168.2.212`
  （不是文档示例的 .140/.1），且官方 App 的控制链路跑在 TCP 7001

## 排错

| 现象 | 处理 |
|---|---|
| `tcpdump: rvi0: No such device exists` | 手机重新插拔后远程网卡失效——脚本会自动重新挂载；若 `rvictl` 报 "Could not get list of devices"，解锁手机稍候几秒重跑脚本 |
| `rvictl: could not start` | 确认 USB 线连接、手机已信任本机；拔插 USB 后重试 |
| 抓包文件不增长 | 手机未在相机热点网段通信——确认 Wi-Fi 已连 OsmoAction4-xxx |
