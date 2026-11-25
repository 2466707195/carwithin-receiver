import Foundation
import SwiftUI
import UIKit

/// 接收端主控：WebSocket 会话、视频管线、伴音、触摸回传、统计与自动重连。
///
/// 协议细节见 `CWProtocol.swift`（来自 CarWithin 源码里的网页接收端脚本）。
@MainActor
final class ReceiverController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting
        case waiting       // 已连上，等第一帧
        case streaming
        case failed(String)
    }

    // MARK: - 连接状态

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = "未连接"
    @Published private(set) var videoFormat: CWVideoFormat?
    @Published private(set) var audioAvailable = false
    @Published private(set) var formatSummary = ""

    // MARK: - 统计

    @Published private(set) var latencyMilliseconds: Double = 0
    @Published private(set) var fps: Int = 0
    @Published private(set) var megabits: Double = 0
    @Published private(set) var droppedFrames: Int = 0
    @Published private(set) var keyframeRequests: Int = 0
    @Published private(set) var audioPackets: Int = 0

    // MARK: - 设置（持久化）

    @Published var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }
    @Published var portText: String {
        didSet { defaults.set(portText, forKey: Key.port) }
    }
    @Published var audioEnabled: Bool {
        didSet {
            defaults.set(audioEnabled, forKey: Key.audio)
            updateAudioSubscription()
        }
    }
    @Published var preferHEVC: Bool {
        didSet { defaults.set(preferHEVC, forKey: Key.hevc) }
    }
    @Published var followScreen: Bool {
        didSet { defaults.set(followScreen, forKey: Key.follow) }
    }
    @Published private(set) var recents: [String]

    let pipeline = VideoPipeline()
    let audio = AudioOutput()
    let viewerID: String

    // MARK: - 内部状态

    private let defaults = UserDefaults.standard
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveLoop: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sendChain: Task<Void, Never>?

    private var wantsConnection = false
    private var attempt = 0
    private var readySent = false
    private var audioSubscribed = false
    private var connectStartedAt = Date()

    private var clockOffset: Double?
    private var bestRTT = Double.infinity
    private var lastClockSample = Date.distantPast
    private var latencySamples: [Double] = []

    private var lastKeyframeRequest = Date.distantPast
    private var framesReceived = 0
    private var bytesReceived = 0
    private var lastTickFrames = 0
    private var lastTickBytes = 0
    private var lastTickAt = Date()

    private var lastPointSize: CGSize = .zero
    private var lastSentPixelWidth = 0
    private var lastSentPixelHeight = 0

    private enum Key {
        static let host = "cw.host"
        static let port = "cw.port"
        static let audio = "cw.audio"
        static let hevc = "cw.hevc"
        static let follow = "cw.follow"
        static let viewer = "cw.viewer"
        static let recents = "cw.recents"
    }

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: Key.host) ?? ""
        portText = defaults.string(forKey: Key.port) ?? "9888"
        audioEnabled = defaults.object(forKey: Key.audio) as? Bool ?? true
        preferHEVC = defaults.object(forKey: Key.hevc) as? Bool ?? false
        followScreen = defaults.object(forKey: Key.follow) as? Bool ?? true
        recents = defaults.stringArray(forKey: Key.recents) ?? []

        if let saved = defaults.string(forKey: Key.viewer), UUID(uuidString: saved) != nil {
            viewerID = saved
        } else {
            let identifier = UUID().uuidString
            defaults.set(identifier, forKey: Key.viewer)
            viewerID = identifier
        }
    }

    // MARK: - 对外操作

    var isStreaming: Bool { phase == .streaming }
    var isBusy: Bool {
        switch phase {
        case .connecting, .waiting, .streaming: return true
        case .idle, .failed: return false
        }
    }

    var port: UInt16 {
        UInt16(portText.trimmingCharacters(in: .whitespaces)) ?? 9888
    }

    func connect(to address: String? = nil) {
        let target = (address ?? host).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            phase = .failed("先填写运行 CarWithin 的 iPhone 的 IP 地址")
            statusText = "缺少地址"
            return
        }
        host = target
        remember(target)
        wantsConnection = true
        attempt = 0
        open()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopNetwork()
        pipeline.reset()
        audio.deactivateSession()
        videoFormat = nil
        formatSummary = ""
        phase = .idle
        statusText = "未连接"
        resetStats()
    }

    /// 回到前台后，如果用户仍想连接但 socket 已经没了，重新连一次。
    func resumeIfNeeded() {
        guard wantsConnection, socket == nil else { return }
        attempt = 0
        open()
    }

    func sendTouches(_ points: [CWTouchPoint]) {
        guard readySent else { return }
        let payload: [[String: Any]] = points.map {
            ["id": $0.id,
             "x": (($0.x * 10_000).rounded()) / 10_000,
             "y": (($0.y * 10_000).rounded()) / 10_000]
        }
        send(["type": "touches", "points": payload])
    }

    func updateDisplay(pointSize: CGSize? = nil, force: Bool = false) {
        if let pointSize, pointSize.width > 1, pointSize.height > 1 {
            lastPointSize = pointSize
        }
        guard readySent else { return }

        let size: CGSize
        if followScreen, lastPointSize.width > 1 {
            size = lastPointSize
        } else {
            size = CGSize(width: 640, height: 360)
        }

        let scale = UIScreen.main.scale
        var width = Int((size.width * scale).rounded())
        var height = Int((size.height * scale).rounded())
        guard width >= 160, height >= 160 else { return }
        width = min(width, 8192)
        height = min(height, 8192)

        if !force, abs(width - lastSentPixelWidth) < 8, abs(height - lastSentPixelHeight) < 8 {
            return
        }
        lastSentPixelWidth = width
        lastSentPixelHeight = height

        let screen = UIScreen.main.bounds.size
        send(["type": "display",
              "w": width,
              "h": height,
              "dpr": Double(scale),
              "sw": Int(screen.width * scale),
              "sh": Int(screen.height * scale),
              "hz": UIScreen.main.maximumFramesPerSecond,
              "h265": preferHEVC,
              "fullscreen": true,
              "ua": "CarWithinReceiver/1.0 (iOS)"])
    }

    func requestKeyframe(_ reason: String) {
        guard readySent else { return }
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequest) > 1.0 else { return }
        lastKeyframeRequest = now
        keyframeRequests += 1
        send(["type": "keyframe", "reason": String(reason.prefix(40))])
    }

    // MARK: - 连接

    private func open() {
        reconnectTask = nil
        stopNetwork()
        pipeline.reset()
        audio.teardown()
        readySent = false
        audioSubscribed = false
        videoFormat = nil
        formatSummary = ""
        clockOffset = nil
        bestRTT = .infinity
        resetStats()

        phase = .connecting
        statusText = "正在连接 \(host):\(port)…"
        connectStartedAt = Date()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 0
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: configuration)
        urlSession = session

        guard let url = URL(string: "ws://\(host):\(port)/stream") else {
            phase = .failed("地址格式不正确")
            statusText = "地址格式不正确"
            return
        }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task
        task.resume()
        listen(on: task)
        startHeartbeat()
    }

    private func stopNetwork() {
        receiveLoop?.cancel()
        receiveLoop = nil
        heartbeat?.cancel()
        heartbeat = nil
        sendChain = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func listen(on task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while true {
                guard let self else { return }
                do {
                    let message = try await task.receive()
                    self.handle(message, from: task)
                } catch {
                    self.handleClose(task: task)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, from task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        if !readySent {
            readySent = true
            statusText = "已连接，正在等待画面"
            send(["type": "ready",
                  "decoder": "webcodecs",
                  "viewer": viewerID,
                  "audioClock": true])
        }
        switch message {
        case .string(let text):
            handleText(text)
        case .data(let data):
            handleBinary(data)
        @unknown default:
            break
        }
    }

    private func handleText(_ text: String) {
        guard let object = CWMessage.parse(text), let type = object["type"] as? String else { return }
        switch type {
        case "hello":
            audioAvailable = object["audio"] as? Bool ?? false
            updateAudioSubscription()
            updateDisplay(force: true)

        case "status":
            if phase != .streaming {
                statusText = object["text"] as? String ?? statusText
            }

        case "format":
            guard let format = CWMessage.format(object) else { return }
            videoFormat = format
            formatSummary = "\(format.name) · \(format.width)×\(format.height) · \(format.fps) fps"
            if pipeline.configure(format) {
                if phase != .streaming { phase = .waiting }
                statusText = "正在解码 \(format.name)…"
            } else {
                statusText = "无法解码 \(format.name)"
                phase = .failed("无法解码 \(format.codec)，请在 CarWithin 改用 H.264")
            }

        case "pong":
            guard let t0 = (object["t0"] as? NSNumber)?.doubleValue,
                  let server = (object["s"] as? NSNumber)?.doubleValue else { return }
            let now = CWClock.micros
            let rtt = now - t0
            if rtt < bestRTT * 1.5 || Date().timeIntervalSince(lastClockSample) > 30 {
                clockOffset = server - (t0 + now) / 2
                bestRTT = min(bestRTT, rtt)
                lastClockSample = Date()
            }

        default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        guard let head = data.first else { return }

        if head == CWPacketKind.audio.rawValue {
            guard audioEnabled, audioSubscribed, let packet = CWPacketParser.audio(from: data) else { return }
            audio.enqueue(packet)
            return
        }

        guard let frame = CWPacketParser.video(from: data) else { return }
        bytesReceived += frame.sample.count + 9
        framesReceived += 1

        if let offset = clockOffset {
            let latency = (CWClock.micros + offset - Double(frame.timestampMicros)) / 1000
            if latency > -50, latency < 5000 {
                latencySamples.append(latency)
                if latencySamples.count > 120 { latencySamples.removeFirst(60) }
            }
        }

        pipeline.enqueue(frame)

        if phase != .streaming {
            phase = .streaming
            attempt = 0
            if let format = videoFormat {
                statusText = "\(format.name) · \(format.width)×\(format.height) · \(format.fps) fps"
            }
        }
    }

    private func handleClose(task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        stopNetwork()
        pipeline.reset()
        audio.teardown()
        readySent = false
        videoFormat = nil
        formatSummary = ""

        guard wantsConnection else {
            phase = .idle
            statusText = "未连接"
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        phase = .connecting
        let delay = min(6.0, 0.5 * pow(2, Double(min(attempt, 4))))
        attempt += 1
        statusText = "连接中断，\(String(format: "%.1f", delay)) 秒后重连…"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.wantsConnection, self.socket == nil else { return }
            self.open()
        }
    }

    // MARK: - 心跳 / 统计 / 看门狗

    private func startHeartbeat() {
        heartbeat?.cancel()
        lastTickAt = Date()
        lastTickFrames = framesReceived
        lastTickBytes = bytesReceived
        heartbeat = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard socket != nil, readySent else { return }
        send(["type": "ping", "t0": CWClock.micros])
        updateStats()

        let now = Date()
        if let last = pipeline.lastFrameAt {
            if now.timeIntervalSince(last) > 2.5 {
                requestKeyframe("长时间无画面")
            }
        } else if now.timeIntervalSince(connectStartedAt) > 6 {
            requestKeyframe("等待关键帧")
            if phase == .waiting, now.timeIntervalSince(connectStartedAt) > 10 {
                statusText = "已连接但没有画面，正在请求关键帧…"
            }
        }

        if pipeline.needsKeyframe, phase == .streaming {
            requestKeyframe("等待关键帧")
        }
    }

    private func updateStats() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastTickAt), 0.001)
        fps = Int(Double(framesReceived - lastTickFrames) / elapsed)
        megabits = Double(bytesReceived - lastTickBytes) * 8 / 1_000_000 / elapsed
        lastTickAt = now
        lastTickFrames = framesReceived
        lastTickBytes = bytesReceived
        droppedFrames = pipeline.droppedFrames
        audioPackets = audio.packets

        if !latencySamples.isEmpty {
            let sorted = latencySamples.sorted()
            latencyMilliseconds = sorted[sorted.count / 2]
            latencySamples.removeAll()
        }
    }

    private func resetStats() {
        fps = 0
        megabits = 0
        droppedFrames = 0
        latencyMilliseconds = 0
        keyframeRequests = 0
        framesReceived = 0
        bytesReceived = 0
        lastTickFrames = 0
        lastTickBytes = 0
        latencySamples.removeAll()
        lastTickAt = Date()
    }

    // MARK: - 发送

    private func updateAudioSubscription() {
        guard readySent else { return }
        let wanted = audioEnabled && audioAvailable
        guard wanted != audioSubscribed else { return }
        audioSubscribed = wanted
        send(["type": "audio", "enabled": wanted])
        if !wanted {
            audio.teardown()
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        // 串行发送：触摸消息带的是「当前全部手指」，乱序会让画面上的手指跳一下。
        let previous = sendChain
        sendChain = Task { [weak self] in
            _ = await previous?.value
            guard let self, self.socket === socket else { return }
            try? await socket.send(.string(text))
        }
    }

    // MARK: - 最近使用

    private func remember(_ address: String) {
        var updated = recents.filter { $0 != address }
        updated.insert(address, at: 0)
        if updated.count > 6 { updated = Array(updated.prefix(6)) }
        recents = updated
        defaults.set(updated, forKey: Key.recents)
    }

    func forget(_ address: String) {
        recents.removeAll { $0 == address }
        defaults.set(recents, forKey: Key.recents)
    }
}
