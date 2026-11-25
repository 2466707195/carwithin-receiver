import SwiftUI

/// 连接页：填地址 / 扫局域网 / 最近使用 / 显示与声音选项。
struct ConnectScreen: View {

    @EnvironmentObject private var controller: ReceiverController
    @StateObject private var scanner = LANScanner()
    @State private var showSteps = true

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                AppTopBar(title: "CarWithin 接收端",
                          subtitle: "接收同一 Wi-Fi 下 iPhone 的 CarPlay 画面")
                AuroraScrollView(bottomInset: 28) {
                    statusCard
                    addressCard
                    optionsCard
                    stepsCard
                }
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusTint.tint(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: statusIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(statusTint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Text(controller.statusText)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle: return "等待连接"
        case .connecting: return "正在连接"
        case .waiting: return "已连接，等待画面"
        case .streaming: return "正在接收"
        case .failed: return "连接失败"
        }
    }

    private var statusIcon: String {
        switch controller.phase {
        case .idle: return "moon.zzz"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .waiting: return "hourglass"
        case .streaming: return "play.rectangle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch controller.phase {
        case .idle: return Aurora.muted
        case .connecting: return Aurora.warning
        case .waiting: return Aurora.info
        case .streaming: return Aurora.success
        case .failed: return Aurora.danger
        }
    }

    // MARK: - 地址

    private var addressCard: some View {
        SectionCard {
            Text("手机地址")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
            Text("填 CarWithin「局域网接收页」显示的地址，端口一般不用改。")
                .font(AuroraFont.bodySmall)
                .foregroundStyle(Aurora.muted)
                .padding(.top, 2)
                .padding(.bottom, 10)

            AuroraTextField(placeholder: "192.168.1.20",
                            text: $controller.host,
                            systemIcon: "wifi",
                            keyboardType: .numbersAndPunctuation)

            HStack(spacing: 8) {
                AuroraTextField(placeholder: "9888",
                                text: $controller.portText,
                                systemIcon: "number",
                                keyboardType: .numberPad)
                    .frame(width: 118)
                SmallTonalButton(text: scanner.isScanning ? "扫描中…" : "扫描局域网",
                                 systemIcon: "dot.radiowaves.left.and.right",
                                 enabled: !scanner.isScanning) {
                    if scanner.isScanning {
                        scanner.cancel()
                    } else {
                        scanner.scan(port: controller.port)
                    }
                }
            }
            .padding(.top, 8)

            if !scanner.hosts.isEmpty {
                VStack(spacing: 6) {
                    ForEach(scanner.hosts, id: \.self) { host in
                        Button {
                            controller.connect(to: host)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "iphone.radiowaves.left.and.right")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Aurora.brand)
                                Text(host)
                                    .font(AuroraFont.bodyMedium)
                                    .foregroundStyle(Aurora.ink)
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                                Text("连接")
                                    .font(AuroraFont.labelSmall)
                                    .foregroundStyle(Aurora.brand)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(AuroraShape.control.fill(Aurora.brand.tint(0.07)))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .padding(.top, 10)
            } else if scanner.isScanning {
                Text("正在扫描本机网段，找到的手机会显示在这里…")
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.muted)
                    .padding(.top, 8)
            } else if scanner.localPrefix == nil {
                Text("没有读到本机 Wi-Fi 网段，请确认已连上 Wi-Fi 后重试。")
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.warning)
                    .padding(.top, 8)
            }

            PrimaryButton(text: "连接", systemIcon: "play.fill") {
                controller.connect()
            }
            .padding(.top, 12)

            if !controller.recents.isEmpty {
                Divider()
                    .overlay(Aurora.hairline)
                    .padding(.vertical, 12)
                Text("最近使用")
                    .font(AuroraFont.labelSmall)
                    .foregroundStyle(Aurora.muted)
                VStack(spacing: 0) {
                    ForEach(controller.recents, id: \.self) { host in
                        HStack(spacing: 8) {
                            Button {
                                controller.connect(to: host)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Aurora.muted)
                                    Text(host)
                                        .font(AuroraFont.bodyMedium)
                                        .foregroundStyle(Aurora.ink)
                                        .monospacedDigit()
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                controller.forget(host)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Aurora.muted)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 选项

    private var optionsCard: some View {
        SectionCard {
            Text("显示与声音")
                .font(AuroraFont.titleSmall)
                .foregroundStyle(Aurora.ink)
                .padding(.bottom, 6)

            toggleRow(title: "跟随本机屏幕",
                      detail: "按当前窗口尺寸通知 iPhone，画面更贴合屏幕；旋转时会重新协商一次。",
                      isOn: $controller.followScreen)
            Divider().overlay(Aurora.hairline).padding(.vertical, 8)
            toggleRow(title: "接收伴音",
                      detail: "需要 iPhone 的「声音」设为「随画面传输（Wi-Fi）」，否则不会有声音。",
                      isOn: $controller.audioEnabled)
            Divider().overlay(Aurora.hairline).padding(.vertical, 8)
            toggleRow(title: "优先 H.265",
                      detail: "画质更高、带宽更省；老设备解不动时关掉，让 iPhone 用 H.264。",
                      isOn: $controller.preferHEVC)
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AuroraFont.labelLarge)
                    .foregroundStyle(Aurora.ink)
                Text(detail)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Aurora.brand)
        }
    }

    // MARK: - 说明

    private var stepsCard: some View {
        SectionCard {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSteps.toggle() }
            } label: {
                HStack {
                    Text("怎么用")
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Spacer()
                    Image(systemName: showSteps ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Aurora.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSteps {
                VStack(alignment: .leading, spacing: 9) {
                    step(1, "iPhone 打开 CarWithin，按提示保存 Wi-Fi 后点「启动 CarPlay」。")
                    step(2, "「设置 → 当前输出」选择「浏览器」，进入「输出设置」打开「局域网接收页」。")
                    step(3, "把两台设备连到同一 Wi-Fi，把 App 上显示的 HTTP 地址填到上面（默认端口 9888）。")
                    step(4, "点「连接」。出画面后直接在画面上滑动、点按，触控会回传给 CarPlay。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Aurora.brand))
            Text(text)
                .font(AuroraFont.bodySmall)
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
