# Design

## Context

- 协议依据（均在 OA4/Nano/Pocket3 实测）：osmosis `MEDIA_PROTOCOL.md`（命令三元组、分页、清单解析、ackSeq、OA4 句柄表 `0x00040000/0x10`、storage=0）与 osmocam PROTOCOL.md §9（下载 URL、.THM、删除确认）。二者互证。
- 本项目 datalink（`OSMOCameraLink`）已具备：`sendRequest` 单发等应答、心跳/ACK、`02/80` 状态推送（mediaMode 位已在 `OSMOStatusSnapshot`）。
- 素材页（media-browse）已有外壳与空态，等数据接入。

## Goals / Non-Goals

**Goals**：列表分页、缩略图、下载（断点续传）、删除（确认）、媒体模式编排、OA4 单元测试；真机自动化回归（diag.log）。
**Non-Goals**：收藏/精彩时刻/连拍组展开/.LRF 预览/多选批量操作；Android 端。

## Decisions

1. **协议层落 OpenMimoProtocol**（`OSMOMedia.swift` + `OSMOMediaSession.swift`）：清单解析为纯函数（Data→[OSMOMediaFile]），与传输解耦，可直接用 golden 样本做单测；会话编排（进入/心跳/分页/HTTP）单独一个类，依赖 `OSMOCameraLink`。
2. **00/27 推送钩子**：`OSMOCameraLink.parseDUML` 对未消费帧新增 `onUnhandledDUML` 回调（cmdSet/cmdId/sender/payload，返回是否消费）；媒体会话注册 00/27 收集器。理由：00/27 是无请求配对的服务端推送，不能走 request/response。备选全局 dispatch 改造——不值得。
3. **播放模式进入与维持**：先试 `02/0C`，1s 内 mediaMode 位未置位即走 OA4 实测路线 `01/01` 双脉冲（A `03…07 01` ×6 @20Hz → B `00…04 01` @20Hz 直至 bit30 置位，唯一完成信号）；维持 = 1Hz `00/88` 0x17 心跳（14B `17 00 46 23 7C "APP" 00×5 02`）。无退出命令：停止心跳后相机自行返回拍摄模式（osmosis §13b 明示），退出素材页后调用 `resumeOSMOLiveView()` 恢复预览。
4. **分页 v1**：自动拉最新页（cursor 0x00000001，页大小 45），「加载更早」按钮以"上一页最旧视频句柄"翻页，上限 20 页；`0c 01` 出现即到底。OA4 单 SD 存储（storage=0），内置存储游标留接口不启用。
5. **HTTP**：URLSession + `http://192.168.2.1`；下载用 `downloadTask` + If-Range 续传（206），写入 Documents/Media/；缩略图 256px JPEG 用 dataTask + NSCache。Info.plist 增加 `NSAppTransportSecurity/NSAllowsArbitraryLoads=YES`（应用仅相机生态用 HTTP，其余全部 HTTPS）。
6. **预览恢复**：`ConnectionFlow` 暴露 `resumeOSMOLiveView()`（调 link 的 startLiveView）与 `activeOSMOLink` 只读访问；媒体页离开时先 `leave()`（02/0C 退出）再恢复预览。复用 flow 的 datalink（相机单客户端），不新建会话。
7. **UI**：`MediaLibraryModel: ObservableObject`（app 层，包装 OSMOMediaSession，桥接 logSink→AppDiagnostics）；`MediaBrowseView`：loading/空态/网格三态，网格项 = 缩略图 + 角标 + 名称/时长；点项弹详情 sheet（下载进度/删除确认 Dialog）；错误横幅沿用控制页样式。
8. **测试**：从 osmosis `Oa4ManifestTest.kt` 提取 OA4 golden manifest hex 作 Swift 用例（解析字段全断言），另加分块重组（乱序/end 先到）、`0c 01` 结尾、分页去重用例；HTTP 部分不进单测（真机验证）。

## Risks / Trade-offs

- [OA4 清单布局与 Nano 有差异（星标位、字段顺序）] → 解析器按"两个 path TLV 定记录边界 + 19 06 锚点"实现（对字段顺序不敏感），golden 用 OA4 样本；真机首跑对照记录数与文件名。
- [写入命令 ackSeq 约束（osmosis：错误 ackSeq 静默丢写）] → 删除走既有 `sendRequest`（本项目实测模式切换/录制均可靠）；删除成功后用 `02/DC` 存储变化佐证。
- [媒体模式与控制页互斥（预览停流）] → 进入/退出媒体模式严格跟随素材页生命周期；离开时恢复预览，若 5s 内无帧由既有流异常自愈兜底。
- [HTTP 明文被 ATS 拦截] → Info.plist 显式放行；仅相机地址使用。
- [未挂载即查询返回空流] → 对空页（仅 start）延迟 1s 重试至多 2 次（spec 场景）。

## Migration Plan

协议层 + UI 一次落地；真机自动化（`--auto-connect --auto-media` 拉取 diag.log 验证清单与下载）+ 人工点验删除。回滚 = revert 提交（无数据迁移）。

## Open Questions

- 无（分页上限 20 页、下载目录 Documents/Media/ 为实现默认，可后调）。
