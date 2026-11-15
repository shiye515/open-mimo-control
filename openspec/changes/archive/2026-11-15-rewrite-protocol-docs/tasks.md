# Tasks

## 1. 目录重组

- [x] 1.1 `git mv docs/protocol docs/protocol-raw`（保留 git 历史）
- [x] 1.2 新建 `docs/protocol/`，并将 `samples/`、`tools/` 从 protocol-raw 移入（实现资源随新文档）
- [x] 1.3 `docs/protocol-raw/README.md` 顶部追加归档声明（已由新 protocol/ 取代，仅供溯源）
 - [x] 1.4 修正仓库内对新目录的引用（docs/protocol/README.md 重写时一并处理；检查根 README.md 与 capture-scripts/README.md 中的 `docs/protocol/` 链接指向）

## 2. 新协议文档撰写（只含已证实内容）

 - [x] 2.1 `README.md`：协议分层全景（ASCII 栈图）、文档路线图（按实现序）、
      连接总时序（mermaid sequenceDiagram：唤醒→凭据→入网→握手→订阅→就绪）、
      可信度声明与溯源约定（证据节 → protocol-raw）
 - [x] 2.2 `discovery-pairing.md`：BLE 唤醒广播（manufacturer data 尾 6 字节 = MAC）、
      BLE 凭据交换（热点 SSID/密码下发）、WiFi 入网、握手 (0x40,0x00,0x2B)、
      设备信息响应（0xC0,0x07,0x07 名字 / 0x0C WiFi MAC / 0x0C12 BLE MAC / 0x0E07 SN /
      0x1907 地区 / 0x0100 固件 / 0x3200 SN+时间）、RTC 对时 (0x00,0x4A)；
      配对时序图
 - [x] 2.3 `transport.md`：UDP 9004 外层封装（字段布局 ASCII 盒图，Android 20B 与 iOS 34B
      两平台并排；len 编码 u8 / 大包 u16+0x8000 标志；session 3B；seq；ACK 块观察形态）；
      心跳最短形态；48B 保活帧；TCP 7001 存活性通道
 - [x] 2.4 `duml-frame.md`：DUML 帧布局 ASCII 盒图（逐字段）、crc8（0x8C 反射/0x77）与
      CRC16-MCRF4XX（0x8408 反射/0x3692）参考实现（Python，可直接复制）、
      3 组已验证测试向量（真机样例帧 + 期望 CRC）、版本位/长度位说明
 - [x] 2.5 `commands.md`：命令参考——总表（cmdSet/cmdId/cmdType/payload/ACK）+ 分节：
      模式切换 02/E1（mode 码表）、拍照 02/01、录像 02/02、快门 02/28（双粒度规则+码表）、
      EV 02/2E（码 16 基准 1/3 档）、ISO 02/2A（log2(ISO/50)+1 枚举表）、
      白平衡 02/2C（K/100）、FOV 02/8E pid 0x0009（码表）、变焦 02/B8、
      倒计时 02/4A、Pro 0x0000 / EIS 0x0008 / ISO MAX 0x000F / 弱光 0x0030、
      色彩 02/42、分辨率帧率 02/18 写 + cam_video_param_v2 码表；
      每命令附已验证样例帧 hex
 - [x] 2.6 `telemetry.md`：订阅 (0x00,0x99) payload 格式（含 key 名明文 TLV）+ 21 key 清单表
      （含推送频率实测）；已实锤值结构（cam_status、cam_record_time、cam_expo_param @6/16-17/20-22、
      cam_video_param_v2 @0/@1、cam_lens_state、cam_image_effect、portrait_mode）；
      未实锤布局主题清单（原始 hex 记录策略）
 - [x] 2.7 `keepalive-timing.md`：保活/轮询节奏表（iOS 0.2s 三连/1s/2s/4s + 02/8E 1s/3s；
      Android 实测对照 0x8e02 ~9.3/s、0x4f00 1/s、0x2b00 2.5s、0xda03 1s）+
      ASCII 时间轴；00/76 JSON 事件；最低保活集建议（iOS 实测：缺 statusPoll 掉帧）
 - [x] 2.8 `platform-notes.md`：iOS/Android 官方 app 差异表（外层头 34B/20B、ACK 块 24B/8B、
      轮询节奏、TCP 7001 使用）、复现建议（按 iOS 节奏实现）、大包 len 编码
 - [x] 2.9 每份文档末尾"证据"节：链接 protocol-raw 对应文档与 pcap 时段

## 3. 校验

 - [x] 3.1 隐私终扫：`docs/protocol/` 全文 grep 设备标识模式（MAC/SN/密码/相机名后缀/型号/固件串）零残留
 - [x] 3.2 内容甄别复核：新文档中每条协议事实能在 protocol-raw 或 pcap 中找到出处（抽查 cmd 表逐行）
 - [x] 3.3 图表渲染检查：mermaid 代码块语法合法、ASCII 图对齐
 - [x] 3.4 `docs/protocol/README.md` 索引链接与实际文件一致；protocol-raw 交叉引用不破坏
 - [x] 3.5 `openspec validate rewrite-protocol-docs` 通过
