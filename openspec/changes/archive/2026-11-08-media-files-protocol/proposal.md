# Proposal

## Why

素材浏览页目前只有空态外壳（`media-browse`，redesign-ui-three-screens），协议层没有任何文件列表/下载/删除能力。相机的媒体协议已有可对照的开源实测实现（osmosis `MEDIA_PROTOCOL.md` + osmocam PROTOCOL.md §9，二者均在 Osmo Action 4 上验证过清单解析），具备落地条件。

## What Changes

- **媒体协议层（OpenMimoProtocol）**：
  - 进入/维持/退出媒体（回放）模式：`02/0C [01 01 00 01|00 00]` + 1Hz `00/88` 子命令 `0x17` 心跳 + 每 ~10s 重申；确认位为 `02/80` bit30（mediaMode，快照已有）。
  - 文件列表分页查询：`00/26`（cursor `0x00000001`=SD 最新页 / 文件句柄=更早页，页大小 45），应答 `00/27` 分块（10B 子头 `4A <type> <len> <counter> <seq> 00 00`，start/data/end），按 DUML 命令过滤并以「最后数据块（len bit12）+ 序号齐备」判定完整。
  - 清单解析：`[u32 count][record…]`，记录以 `19 06` 标记锚定（T-18 FAT 时间、T-14 大小、T-10 句柄、T-6 时长、T-3 分辨率、T-2 类型、T-4 帧率码），TLV `0d` 文件名（扩展名）、`1a…01` 媒体路径、`1a…02` 缩略图路径；`0c 01` TLV = 库结尾。
  - 删除：`00/28 [count][handles…][counter] 00 [count] 01 01 00 00`，应答 `0000`=成功。
  - HTTP 下载（80 端口）：`GET /v2?storage=<0|1>&path=<path>.<EXT>`，支持 Range 断点续传；缩略图 = 缩略图路径 + `.THM`（JPEG）。
- **应用层**：素材浏览页接入真实数据——进入页面进入媒体模式并拉取最新页，网格展示缩略图/文件名/时长/视频照片角标，点击文件弹出详情（下载含进度、删除需确认），「加载更早」按游标翻页；离开页面退出媒体模式并恢复实时预览。
- **配套**：Info.plist 放开相机地址的 HTTP（ATS）；协议事实沉淀 `docs/protocol/media-files.md`；清单解析用 osmosis 的 OA4 golden 样本做单元测试。
- **范围外**：收藏 `02/BF`、精彩时刻标记 `02/FF`、连拍组展开、`.LRF` 低清预览、DNG/WAV 未列出文件。

## Capabilities

### New Capabilities

- `media-files`: 相机媒体文件的查询/缩略图/下载/删除协议与素材页数据接入（媒体模式的进入与维持、分页清单、HTTP 下载）。

### Modified Capabilities

<!-- 无：media-browse 页面外壳规格（空态/布局/导航）不变；文件数据由本能力提供 -->

## Impact

- 代码：`OpenMimoProtocol/Sources`（新增 OSMOMedia 清单解析/收集器、OSMOMediaSession 编排、OSMOCameraLink 增加 00/27 推送钩子与播放模式维持）、`MediaBrowseView.swift`（真实数据网格 + 详情/下载/删除）、`ConnectionFlow`（暴露活动 datalink 与恢复预览）、Info.plist（ATS）。
- 复用：既有 `sendRequest`（单发等应答）、心跳/ACK 序列、`OSMOStatusSnapshot.mediaMode`。
- 测试：协议包单元测试（OA4 golden manifest）、真机自动化（`--auto-connect --auto-media` 拉 diag.log）。
- 协议依据：`docs/reference` 引用的 osmosis MEDIA_PROTOCOL.md、osmocam PROTOCOL.md §9（OA4 实测），沉淀到 `docs/protocol/media-files.md`。
