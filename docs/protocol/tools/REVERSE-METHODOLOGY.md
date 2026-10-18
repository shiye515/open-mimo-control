# 逆向工具与方法论（Android 官方 app 协议分析）

> 本文档沉淀 2026-11-13/15 两轮 Android 官方 Mimo app 逆向的完整工具链与方法论，
> 产出见 [frame-format-android-csdk.md](../frame-format-android-csdk.md)、
> [cmd-map-android-csdk.md](../cmd-map-android-csdk.md)、[capture-analysis-android-20261114.md](../capture-analysis-android-20261114.md)。

## 隐私规范（公开仓库必读）

入库前必须脱敏，逐项替换为 `**`：

| 类别 | 示例模式 |
|---|---|
| 相机热点密码（含大小写变体） | 屏显密码与真实密码可能大小写不同，两种都要替换 |
| MAC 地址（WiFi/BLE，含截断形态） | `e4:**` 前缀、尾号等任何可识别片段 |
| 序列号（SN） | 0x3200 应答中的 14 字符串 |
| 相机名 / SSID 唯一后缀 | 保留机型名 `OsmoAction4`，去掉 `-****` 后缀 |
| 手机型号 / 固件版本串 | 0x0100 应答中的版本串 |

**二进制抓包文件（.pcap/.pcapng）无法文本脱敏，一律不入库**（内含全部真实流量）。
建议 `.gitignore`：

```
*.pcap
*.pcapng
```

## 一、抓包方法论（无 root Android）

标准途径是三星工程菜单 **SysDump（拨号 `*#9900#`）→ TCP DUMP START**：
系统级 tcpdump，不需要 root，不依赖 VPN（VpnService 方案对"无互联网私有热点"
场景必然失败——VPN 截流后无法回转，见 capture-analysis §风险）。

1. **启动**：`TCP DUMP START` → Android 15+ 需 6 位 OTP（弹窗显示 key，
   用 [tools/sysdump-otp.py](sysdump-otp.py) 以手机时钟计算，5 分钟窗口有效）；
2. **操作**：按预定序列操作 app，**每步之间停 5–10 秒**——空闲段是流量切分的依据；
   记录每步时刻（双保险）；
3. **停止**：再点一次 TCP DUMP；
4. **导出**：pcap 落在 `/data/log/tcpdump/`（adb 不可读），需 SysDump 里
   **Copy to sdcard** 复制到 `/sdcard/log/tcpdump/`，再 `adb pull`；
5. 注意 bugreport **不包含** tcpdump 目录，也不包含 btsnoop（One UI 裁剪）。

对照法设计要点：一次会话覆盖多个功能，每步一个功能 + 停顿切分；
参数类操作**连调 2 档**（3 个递增样本才能区分"枚举 +1"与"值本身"）；
**记录改前/改后实际档位值**——payload 字节与实际值的配对是解码枚举的关键。

## 二、解析工具链

[tools/pcap_9004.py](pcap_9004.py)：UDP 9004 会话解析器（纯 Python，无依赖），
支持 `session / timeline / burst / ascii` 四种模式，另可直接 import 复用
`load_packets()`（已处理 LINUX_SLL 与 DUML 帧定位）。

分析套路：

1. `session` 看流量结构（方向 × 头模式 × 长度）；
2. `timeline` 按秒找非心跳突增 = 用户操作时刻；
3. `burst <时刻>` 提取操作帧 payload；
4. 响应与请求 cmd 相同、结构对称，成对解读。

DUML 帧格式与 CRC（crc8 poly 0x8C/init 0x77；CRC16-MCRF4XX 0x8408/init 0x3692）
见 [control-channel.md](../control-channel.md) §1，`parse_mimo_capture.py --crc-test` 可复算。
注意外层封装存在**平台差异**（Android 头 20B / iOS 头 34B，ACK 块长度不同），
且大包（>255B）len 用 u16 LE + 0x8000 标志。

## 三、Ghidra headless 工具链（native 库逆向）

**安装要点**（macOS ARM64）：Ghidra 12.2 官方 zip 不含 mac 反编译器二进制，
需自建——`Ghidra/Features/Decompiler/src/decompile/cpp && make ghidra_opt`，
产物复制为 `os/mac_arm_64/decompile`。脚本用 **Java**（12.2 已移除 Jython，
Python 需另装 PyGhidra）。

```bash
# 项目首次导入 + 分析（libdjisdk_jni.so 43MB 约 15-40 分钟，此后复用秒级）
analyzeHeadless ~/work/dji-research/ghidra-proj dji-csdk \
  -import <so 路径> -scriptPath tools/ghidra -postScript GhidraDecompExport.java
# 已分析项目上跑新脚本（免重新分析）
analyzeHeadless ~/work/dji-research/ghidra-proj dji-csdk \
  -process libdjisdk_jni.so -noanalysis -scriptPath tools/ghidra -postScript <脚本>.java
```

[tools/ghidra/](ghidra/) 四个脚本：

| 脚本 | 用途 |
|---|---|
| `GhidraDecompExport.java` | 关键词 + CRC xref 批量导出反编译 C（定位编码器：DjiProtocolEncoder::Encode 即由此命中） |
| `CmdMapExport.java` | 枚举全部 `Send*/Observer*` 模板实例，反编译提取常量 → cmd-map.tsv |
| `KeyXrefExport.java` | key 名字符串反向 xref（key 名 ↔ topic 类型关联） |
| `SearchImmCmd.java` | 按立即数搜指令（验证某 cmd 是否编译期常量） |

**注意事项**（踩过的坑）：
- mangled 名里模板无尖括号（`14SendActionPackIN3...`），关键词匹配用裸名；
- `Instruction.getOpObjects(i)` 需要操作数索引；
- 反编译文本里字符串经 DAT 指针引用，非字面量——key 名提取需走 xref；
- SQLite 等静态链接库会造成立即数误报，命中后须确认所在函数。

## 四、APK 逆向流程

1. `adb shell pm path <pkg>` 拉取 base + 全部 split（dynamic feature 包常藏核心：
   本例 CSDK 在 `split_dynamic_pack_csdk.apk` 的 `assets/mimo-csdk-so.zip` 内）；
2. **侦察先于反编译**：`strings`/`nm -D` 提取 JNI 入口、C++ 符号（常未剥离）、
   proto 类型名（`dji_proto_*_topic_t`）、key 名——零成本拿到协议字典骨架；
3. Java 层（jadx）通常只是薄壳（Flutter/防护/许可校验），业务在 native；
4. 用**抓包已知的协议特征**（端口、SOP、帧头常数、key 名）反查代码位置，
   聚焦反编译目标函数，避免 43MB 库全量盲读；
5. 每个结论用抓包帧**逐字节回验**（如 EV 码 17=+0.3、快门 0x8000|分母），
   并与 iOS 侧既有认知交叉校验（crc8/crc16 双向复算 4131 帧 100% 通过）。

## 五、经验教训

- **字段错位的连锁误读**：把 DUML 的 len/cmdType/cmdSet/cmdId 错位拼成
  "cmd u16"，会导致整条 cmd 映射表失真——iOS 文档早有同类更正记录
  （"早期误将 crc8 字段当作命令字"）。**跨平台互证是纠错的最终手段**：
  4131 帧 CRC 全量校验一次定案；
- 无 root 三星的蓝牙 btsnoop 被 One UI 裁剪且无导出途径（bugreport 不含），
  BLE 协议走 APK Java 层静态分析（jadx）替代；
- 官方 app 的 CSDK 日志（`files/Log/CSDK/`）为 DJI 私有加密格式，不可直接读。
