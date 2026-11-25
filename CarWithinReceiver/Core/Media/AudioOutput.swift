import AVFoundation
import Foundation

/// 伴音输出：CarWithin 在「声音 → 随画面传输（Wi-Fi）」时推送 PCM16 包，
/// 这里用 `AVAudioEngine` 直接播放。
///
/// 只做两件简单的事：按包里的采样率/声道建立格式，把 Int16 交错样本转成 Float32 平面数据。
/// 不做重采样、不补静音——手机和接收端都是实时链路，宁可短暂断一下也不要堆缓冲。
final class AudioOutput {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var engineReady = false
    private var playerAttached = false

    private(set) var packets = 0
    private(set) var failures = 0

    /// 首包到达时按它声明的格式准备引擎。
    @discardableResult
    func configure(sampleRate: Double, channels: Int) -> Bool {
        if let format, format.sampleRate == sampleRate, format.channelCount == UInt32(channels), engineReady {
            return true
        }
        teardown()

        guard let newFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: AVAudioChannelCount(channels),
                                            interleaved: false) else {
            failures += 1
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // 音频会话失败不影响画面，继续尝试引擎。
        }

        engine.attach(player)
        playerAttached = true
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            failures += 1
            teardown()
            return false
        }

        player.play()
        format = newFormat
        engineReady = true
        return true
    }

    func enqueue(_ packet: CWAudioPacket) {
        guard configure(sampleRate: packet.sampleRate, channels: packet.channels) else { return }
        guard let format else { return }

        let channels = packet.channels
        let frames = packet.payload.count / (2 * channels)
        guard frames > 0, frames <= 8192 else {
            failures += 1
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            failures += 1
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let planes = buffer.floatChannelData else {
            failures += 1
            return
        }

        let bytes = [UInt8](packet.payload)
        for channel in 0..<channels {
            let plane = planes[channel]
            for frame in 0..<frames {
                let index = (frame * channels + channel) * 2
                guard index + 1 < bytes.count else { break }
                let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                plane[frame] = Float(Int16(bitPattern: raw)) / 32768
            }
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        packets += 1
    }

    func teardown() {
        if engine.isRunning {
            engine.stop()
        }
        if playerAttached {
            engine.detach(player)
            playerAttached = false
        }
        format = nil
        engineReady = false
    }

    func deactivateSession() {
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
