# Tasks

## 1. 协议层（OpenMimoProtocol）

- [x] 1.1 `OSMOMedia.swift`：`OSMOMediaFile` 模型、00/26 查询/删除/收藏载荷构造、`OSMOMediaListCollector`（00/27 分块重组：子头解析、counter 过滤、按序拼接、完整判定）、`decodeMediaManifest`（path TLV 定界 + `19 06` 锚点 + 字段提取 + `0c 01` 结尾）。验证：单元测试通过。
- [x] 1.2 golden 单元测试：OA4 manifest 样本（osmosis Oa4ManifestTest 夹具）字段断言 + 乱序/end 先到分块 + 空流 + 分页去重。验证：`swift test` 全绿。
- [x] 1.3 `OSMOCameraLink`：新增 `onUnhandledDUML` 钩子（未消费帧回调）、`startLiveView` 公开化（供媒体模式退出后恢复预览）、媒体模式心跳/重申所需发送通道确认。验证：编译通过、既有命令回归不受影响。

## 2. 会话编排

- [x] 2.1 `OSMOMediaSession.swift`：enter/leave（02/0C + mediaMode 确认轮询 + 1Hz beat + 10s 重申 Timer）、`fetchPage(cursor:)`（发送+收集+重试空页）、`loadLibrary(progress:)` 首页加载与游标翻页、`thumbnail(path:storage:)`（URLSession + NSCache）、`download(file:progress:)`（downloadTask + Range 续传 + 沙盒落盘）、`delete(file:)`（00/28 + 应答校验）。验证：编译通过。
- [x] 2.2 `ConnectionFlow`：暴露 `activeOSMOLink` 与 `resumeOSMOLiveView()`；App 侧 `MediaLibraryModel`（桥接 logSink→AppDiagnostics、发布状态）。验证：编译通过。

## 3. UI 与配置

- [x] 3.1 `MediaBrowseView` 接入真实数据：onAppear 进入媒体模式拉首页 / onDisappear 退出并恢复预览；网格（缩略图+视频/照片角标+名称/时长）、加载更早、详情 sheet（信息 + 下载进度 + 删除确认 Dialog）、错误横幅；无会话/空态保留。验证：编译通过，模拟器/真机界面三态正确。
- [x] 3.2 Info.plist：`NSAppTransportSecurity/NSAllowsArbitraryLoads=YES`（相机 HTTP）。验证：真机 HTTP 请求不被 ATS 拦截（diag.log 缩略图/下载成功）。

## 4. 文档与验证

- [x] 4.1 `docs/protocol/media-files.md`：媒体模式、00/26/27、清单布局、删除、HTTP 下载（标注来源 osmosis/osmocam 与 OA4 实测边界）。验证：文档与实现行为一致。
- [ ] 4.2 真机自动化：`--auto-connect --auto-media` 启动，拉 diag.log 验证媒体模式进入、清单页数与文件数、缩略图/下载成功；人工点验删除与翻页。验证：diag.log 证据 + 人工确认。
