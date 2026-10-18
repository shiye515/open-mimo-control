# Spec Delta

## MODIFIED Requirements

### Requirement: 实时画面渲染
控制会话建立后，应用必须（SHALL）接收相机视频流并将其解码渲染在控制页的实时预览区（设计稿中状态区下方的固定高度圆角预览卡片，见 control-screen「主界面布局」）；从会话建立到首帧画面展示必须（SHALL）在数秒内完成，端到端延迟必须（SHALL）低到可支撑取景与构图操作。

#### Scenario: 首帧展示
- **WHEN** 控制会话握手成功且相机开始推流
- **THEN** 应用在数秒内展示实时画面，画面方向与相机朝向一致

#### Scenario: 支持相机当前分辨率
- **WHEN** 相机以某分辨率/帧率档位推流
- **THEN** 应用正确解码该档位画面，无明显花屏或持续丢帧

## REMOVED Requirements

### Requirement: 预览辅助元素
**Reason**: 设计稿的预览卡片仅保留左上角 REC 角标，不再提供构图网格线开关；该功能入口随界面重构移除。
**Migration**: 如后续需要构图辅助，可在预览卡片上重新引入网格线开关（恢复本要求或并入 control-screen 预览相关要求）。
