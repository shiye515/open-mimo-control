//
//  ContentView.swift
//  OpenMimoControl
//
//  Created by OpenMimoControl contributors.
//
//  顶层路由（redesign-ui-three-screens）：连接页 ↔ 控制页 ↔ 素材浏览页。
//  界面实现拆分在 Screens/ 下：ConnectScreenView / ControlScreenView / MediaBrowseView /
//  LivePreviewView / Components / DesignTokens。

import SwiftUI
import AVFoundation
import OpenMimoProtocol

/// 应用顶层路由：连接流程 ↔ 远程控制主界面 ↔ 素材浏览。
enum AppRoute {
    case connect
    case control
    case media
}

/// 跨页面共享的会话容器：连接页建立，控制页/素材页复用。
@MainActor
final class AppSessionHolder {
    static let shared = AppSessionHolder()
    var session: CameraSession?

    /// App 启动时注入：BLE 全流程日志（含帧 hex）与会话状态直通统一诊断面板。
    static func bootstrapDiagnostics() {
        CameraBleWaker.logSink = { line in
            Task { @MainActor in AppDiagnostics.shared.add("[ble] \(line)") }
        }
        CameraSession.logSink = { line in
            Task { @MainActor in AppDiagnostics.shared.add("[session] \(line)") }
        }
    }

    /// 建立到相机网关的会话（地址依据 docs/protocol/discovery.md §1）。
    /// 链路事件写入共享诊断，供控制页真机排查显示。
    static func makeLink() -> NWCameraLink {
        NWCameraLink(host: "192.168.2.1",
                     onEvent: { line in
                         Task { @MainActor in AppDiagnostics.shared.add(line) }
                     },
                     onTCPData: { data in
                         // TCP 7001 RTP 信令：提取 SRTP 密钥（live-view.md §5）
                         if let key = SRTPSignaling.extractKey(data) {
                             let hex = key.map { String(format: "%02x", $0) }.joined()
                             Task { @MainActor in
                                 AppDiagnostics.shared.add("[srtp] 密钥下发: \(hex)")
                                 await AppSessionHolder.shared.session?.deliverSRTPKey(key)
                             }
                         }
                     })
    }
}

struct ContentView: View {
    /// 自动化测试钩子（devicectl launch 传参）：--route-media 直接打开素材页外壳。
    @State private var route: AppRoute = ProcessInfo.processInfo.arguments.contains("--route-media") ? .media : .connect
    @StateObject private var flow = ConnectionFlow()

    init() {
        AppSessionHolder.bootstrapDiagnostics()
    }

    var body: some View {
        Group {
            switch route {
            case .connect:
                ConnectScreenView(onConnected: { route = .control }, flow: flow)
            case .control:
                ControlScreenView(onDisconnect: {
                    Task { await AppSessionHolder.shared.session?.stop() }
                    route = .connect
                }, onMedia: { route = .media }, flow: flow)
            case .media:
                MediaBrowseView(onBack: { route = .control }, flow: flow)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: flow.state) { state in
            // 自动化测试钩子：--auto-media 在连接成功后直接进入素材页
            if case .success = state, ProcessInfo.processInfo.arguments.contains("--auto-media") {
                route = .media
            }
            // 自动化测试钩子：--auto-switch 连接稳定后切换拍摄格式（验证预览在编码器重启后恢复）
            if case .success = state, ProcessInfo.processInfo.arguments.contains("--auto-switch") {
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await flow.autoSwitchAspect()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
