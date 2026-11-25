import SwiftUI
import UIKit

/// 全屏播放页：视频画面铺满，触摸直接回传 CarPlay，HUD 四秒后自动隐藏。
struct PlayerScreen: View {

    @EnvironmentObject private var controller: ReceiverController

    @State private var hudVisible = true
    @State private var showStats = false
    @State private var hudGeneration = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VideoSurface(pipeline: controller.pipeline,
                             videoSize: surfaceSize,
                             onTouches: { controller.sendTouches($0) },
                             onActivity: { wake() })
                    .ignoresSafeArea()

                if controller.phase != .streaming {
                    waitingOverlay
                }

                hud
                    .opacity(hudVisible ? 1 : 0)
                    .allowsHitTesting(hudVisible)
                    .animation(.easeOut(duration: 0.22), value: hudVisible)
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                controller.updateDisplay(pointSize: geo.size, force: true)
                wake()
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: geo.size) { size in
                controller.updateDisplay(pointSize: size)
            }
            .onChange(of: controller.phase) { phase in
                if phase == .streaming { wake() }
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
    }

    private var surfaceSize: CGSize {
        guard let format = controller.videoFormat else { return CGSize(width: 16, height: 9) }
        return CGSize(width: format.width, height: format.height)
    }

    private var failureReason: String? {
        if case .failed(let reason) = controller.phase { return reason }
        return nil
    }

    // MARK: - 等待层

    private var waitingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.2)
            Text(controller.statusText)
                .font(AuroraFont.bodyMedium)
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let reason = failureReason {
                Text(reason)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            DarkChip(text: "退出", systemIcon: "chevron.left") {
                controller.disconnect()
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
    }

    // MARK: - HUD

    private var hud: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                DarkChip(text: nil, systemIcon: "chevron.left") {
                    controller.disconnect()
                }

                VStack(alignment: .leading, spacing: 4) {
                    DarkChip(text: statusLine, systemIcon: nil) {}
                        .allowsHitTesting(false)
                    if showStats {
                        statsPanel
                    }
                }

                Spacer(minLength: 0)

                DarkChip(text: nil, systemIcon: showStats ? "chart.bar.fill" : "chart.bar") {
                    withAnimation(.easeInOut(duration: 0.18)) { showStats.toggle() }
                    wake()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
    }

    private var statusLine: String {
        guard let format = controller.videoFormat else { return controller.statusText }
        return "\(format.name) \(format.width)×\(format.height) · \(controller.fps) fps · \(Int(controller.latencyMilliseconds)) ms"
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            statLine("编码", controller.videoFormat.map { "\($0.name) \($0.codec)" } ?? "-")
            statLine("画面", controller.videoFormat.map { "\($0.width)×\($0.height) @\($0.fps)" } ?? "-")
            statLine("显示", "\(controller.fps) fps")
            statLine("延迟", "\(Int(controller.latencyMilliseconds)) ms")
            statLine("码率", String(format: "%.1f Mbps", controller.megabits))
            statLine("丢帧", "\(controller.droppedFrames)")
            statLine("关键帧请求", "\(controller.keyframeRequests)")
            statLine("伴音", controller.audioAvailable ? (controller.audioEnabled ? "已开启 · \(controller.audioPackets) 包" : "手机未随画面传输") : "手机未开启")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
    }

    private func statLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
        }
    }

    // MARK: - HUD 自动隐藏

    private func wake() {
        hudVisible = true
        hudGeneration += 1
        let generation = hudGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard generation == hudGeneration else { return }
            withAnimation(.easeOut(duration: 0.25)) { hudVisible = false }
        }
    }
}

/// 画面上用的深色小胶囊（视频是黑的，极光玻璃在这里看不清）。
private struct DarkChip: View {

    var text: String?
    var systemIcon: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 12, weight: .bold))
                }
                if let text {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color.black.opacity(0.55))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
