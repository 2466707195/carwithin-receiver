import Foundation

// MARK: - CarWithin 输出协议
//
// 与 CarWithin 内部 `BrowserReceiverPage` 的网页接收端一一对应，来源：CarWithin 1.0.5 源码。
//
// 连接：`ws://<iPhone IP>:9888/stream`
//   - 走 HTTP 端口，不需要证书；HTTPS 端口（默认 9889）只有网页端为了 WebCodecs 才需要。
//
// 握手（客户端 → 服务端，均为 JSON 文本帧）：
//   {"type":"ready","decoder":"webcodecs","viewer":"<uuid>","audioClock":true}
//   {"type":"display","w":1179,"h":2556,"dpr":3,"sw":1179,"sh":2556,"hz":60,"h265":false,"fullscreen":true,"ua":"..."}
//   {"type":"ping","t0":<单调时钟 µs>}        每秒一次，用于估算端到端延迟
//   {"type":"keyframe","reason":"..."}        请求一个 IDR（服务端会限流）
//   {"type":"touches","points":[{"id":0,"x":0.5,"y":0.5}]}   归一化坐标，0…1
//   {"type":"audio","enabled":true}
//
// 服务端 → 客户端：
//   {"type":"hello","page":"…","securePort":9889,"perf":"auto","showTouches":false,"audio":true}
//   {"type":"status","text":"…"}
//   {"type":"format","codec":"avc1.640028","name":"H.264","width":1280,"height":720,"fps":30,
//    "duration":1500,"timescale":90000,"decoder":"webcodecs","description":"<base64 avcC/hvcC>"}
//   {"type":"pong","s":<服务端单调时钟 µs>,"t0":<回显>}
//   二进制：1 字节类型 + 8 字节大端到达时间(µs) + 长度前缀（AVCC/HVCC）样本

/// 二进制帧首字节。声明为 webcodecs 的接收端只会收到 `delta` / `keyframe` / `audio`。
enum CWPacketKind: UInt8 {
    case delta = 0          // 依赖帧（webcodecs 模式）
    case keyframe = 1       // 关键帧（webcodecs 模式）
    case initialization = 2 // MSE 初始化段
    case audio = 3          // PCM16 音频包
    case timedDelta = 4     // MSE 依赖帧 + 时间戳
    case timedKeyframe = 5  // MSE 关键帧 + 时间戳
}

/// 视频参数（服务端 `format` 消息）。
struct CWVideoFormat: Equatable {
    var codec: String
    var name: String
    var width: Int
    var height: Int
    var fps: Int
    /// avcC（H.264）或 hvcC（H.265）解码配置记录，用来构建设备格式描述。
    var decoderRecord: Data?

    var isHEVC: Bool {
        codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") || codec.hasPrefix("hvc")
    }
}

/// 一帧压缩视频。
struct CWVideoFrame {
    var isKeyframe: Bool
    var timestampMicros: UInt64
    /// 长度前缀（4 字节）的 NAL 单元，可直接塞进 CMSampleBuffer。
    var sample: Data
}

/// 一个 PCM16 音频包。
struct CWAudioPacket {
    var timestampMicros: UInt64
    var sampleRate: Double
    var channels: Int
    var stream: Int
    /// 交错排列的 Int16 小端样本。
    var payload: Data
}

/// 触摸点，坐标已归一化到画面矩形内。
struct CWTouchPoint {
    var id: Int
    var x: Double
    var y: Double
}

enum CWPacketParser {

    static func video(from data: Data) -> CWVideoFrame? {
        guard data.count > 9 else { return nil }
        let head = data[data.startIndex]
        guard head == CWPacketKind.delta.rawValue || head == CWPacketKind.keyframe.rawValue else { return nil }
        let stamp = bigEndianUInt64(data, offset: 1)
        let start = data.startIndex + 9
        return CWVideoFrame(isKeyframe: head == CWPacketKind.keyframe.rawValue,
                            timestampMicros: stamp,
                            sample: data.subdata(in: start..<data.endIndex))
    }

    static func audio(from data: Data) -> CWAudioPacket? {
        guard data.count > 15 else { return nil }
        let bytes = [UInt8](data.prefix(15))
        guard bytes[0] == CWPacketKind.audio.rawValue else { return nil }

        let rate = UInt32(bytes[9]) << 24 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 8 | UInt32(bytes[12])
        let channels = Int(bytes[13])
        let stream = Int(bytes[14])
        guard rate >= 8_000, rate <= 48_000, channels >= 1, channels <= 2 else { return nil }

        let payload = data.subdata(in: (data.startIndex + 15)..<data.endIndex)
        guard payload.count >= 2 * channels else { return nil }
        return CWAudioPacket(timestampMicros: bigEndianUInt64(data, offset: 1),
                             sampleRate: Double(rate),
                             channels: channels,
                             stream: stream,
                             payload: payload)
    }

    private static func bigEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            let position = data.startIndex + offset + index
            guard position < data.endIndex else { break }
            value = value << 8 | UInt64(data[position])
        }
        return value
    }
}

/// 解析服务端 JSON 文本帧。
enum CWMessage {

    struct Hello {
        var page: String
        var securePort: Int
        var audio: Bool
        var performance: String
    }

    static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    static func hello(_ object: [String: Any]) -> Hello? {
        guard object["type"] as? String == "hello" else { return nil }
        return Hello(page: object["page"] as? String ?? "",
                     securePort: (object["securePort"] as? NSNumber)?.intValue ?? 0,
                     audio: object["audio"] as? Bool ?? false,
                     performance: object["perf"] as? String ?? "auto")
    }

    static func format(_ object: [String: Any]) -> CWVideoFormat? {
        guard object["type"] as? String == "format",
              let codec = object["codec"] as? String else { return nil }
        var record: Data?
        if let base64 = object["description"] as? String {
            record = Data(base64Encoded: base64)
        }
        return CWVideoFormat(codec: codec,
                             name: object["name"] as? String ?? codec,
                             width: (object["width"] as? NSNumber)?.intValue ?? 1280,
                             height: (object["height"] as? NSNumber)?.intValue ?? 720,
                             fps: (object["fps"] as? NSNumber)?.intValue ?? 30,
                             decoderRecord: record)
    }
}

/// 本机单调时钟（微秒）。和网页端的 `performance.now()` 等价，用来算端到端延迟。
enum CWClock {
    static var micros: Double {
        ProcessInfo.processInfo.systemUptime * 1_000_000
    }
}
