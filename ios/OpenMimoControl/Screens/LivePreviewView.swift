import SwiftUI
import AVFoundation
import OpenMimoProtocol

// MARK: - 实时预览视图（OSMO datalink 管线；设计稿为固定高度圆角预览卡片，
// 高度由 ControlScreenView 传入，REC 角标等 overlay 亦由其叠加）

struct LivePreviewView: View {
    @ObservedObject var flow: ConnectionFlow

    var body: some View {
        ZStack {
            if flow.osmoFrameCount > 0 {
                OSMOVideoLayerView(renderer: flow.osmoRenderer, flow: flow)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(OC.textTertiary)
                    Text("预览待连接")
                        .font(.footnote)
                        .foregroundStyle(OC.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }
}

/// OSMO H.265 渲染层宿主：AVSampleBufferDisplayLayer（硬解+渲染一体）。
struct OSMOVideoLayerView: UIViewRepresentable {
    let renderer: OSMOH265Renderer
    var flow: ConnectionFlow

    final class HostView: UIView {
        var sampleLayer: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            sampleLayer?.frame = bounds
        }
    }

    final class Coordinator {
        var layer: AVSampleBufferDisplayLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .black
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = v.bounds
        v.layer.addSublayer(layer)
        v.sampleLayer = layer
        context.coordinator.layer = layer
        renderer.attach(layer)
        // 挂载前的 IDR 已丢失（P 帧无参考无法解码）：请求新关键帧
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak flow] in
            flow?.requestOSMOKeyframe()
        }
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        uiView.sampleLayer?.frame = uiView.bounds
        CATransaction.commit()
    }
}
