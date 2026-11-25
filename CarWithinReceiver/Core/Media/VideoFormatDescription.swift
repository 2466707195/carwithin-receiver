import CoreMedia
import Foundation
import VideoToolbox

/// 把 `format` 消息里的 avcC / hvcC 解码配置记录转成 CoreMedia 的格式描述。
///
/// CarWithin 发的是「长度前缀」样本（AVCC/HVCC），所以格式描述里必须带
/// 4 字节 NAL 长度前缀的设置，解码器才知道怎么切分 NAL。
enum CWFormatDescriptionBuilder {

    static func make(_ format: CWVideoFormat) -> CMFormatDescription? {
        guard let record = format.decoderRecord, !record.isEmpty else { return nil }
        return format.isHEVC ? hevc(record) : h264(record)
    }

    // MARK: - H.264（avcC）

    private static func h264(_ record: Data) -> CMFormatDescription? {
        let bytes = [UInt8](record)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }

        let nalLength = Int(bytes[4] & 0x03) + 1
        var index = 5

        let spsCount = Int(bytes[index] & 0x1F)
        index += 1

        var sets: [Data] = []
        for _ in 0..<max(spsCount, 0) {
            guard let (set, next) = readSet(bytes, at: index) else { return nil }
            sets.append(set)
            index = next
        }

        guard index < bytes.count else { return nil }
        let ppsCount = Int(bytes[index])
        index += 1
        for _ in 0..<max(ppsCount, 0) {
            guard let (set, next) = readSet(bytes, at: index) else { return nil }
            sets.append(set)
            index = next
        }

        guard !sets.isEmpty else { return nil }
        return parameterSets(sets, nalLength: nalLength, codec: .h264)
    }

    // MARK: - H.265（hvcC）

    private static func hevc(_ record: Data) -> CMFormatDescription? {
        let bytes = [UInt8](record)
        guard bytes.count > 23, bytes[0] == 1 else { return nil }

        let nalLength = Int(bytes[21] & 0x03) + 1
        let arrayCount = Int(bytes[22])
        var index = 23

        /// VPS / SPS / PPS 必须按这个顺序交给 CoreMedia。
        var vps: [Data] = []
        var sps: [Data] = []
        var pps: [Data] = []
        var others: [Data] = []

        for _ in 0..<arrayCount {
            guard index + 3 <= bytes.count else { break }
            let nalType = Int(bytes[index] & 0x3F)
            let count = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
            index += 3
            for _ in 0..<count {
                guard let (set, next) = readSet(bytes, at: index) else { break }
                switch nalType {
                case 32: vps.append(set)
                case 33: sps.append(set)
                case 34: pps.append(set)
                default: others.append(set)
                }
                index = next
            }
        }

        let sets = vps + sps + pps
        guard !sets.isEmpty else { return nil }
        return parameterSets(sets, nalLength: nalLength, codec: .hevc)
    }

    // MARK: - 公共

    private enum Codec {
        case h264
        case hevc
    }

    /// 读取 `[2 字节长度][NAL 数据]`。
    private static func readSet(_ bytes: [UInt8], at index: Int) -> (Data, Int)? {
        guard index + 2 <= bytes.count else { return nil }
        let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        let start = index + 2
        guard length > 0, start + length <= bytes.count else { return nil }
        return (Data(bytes[start..<(start + length)]), start + length)
    }

    private static func parameterSets(_ sets: [Data], nalLength: Int, codec: Codec) -> CMFormatDescription? {
        // 手动分配，避免 `withUnsafeBufferPointer` 的指针逃逸问题。
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for set in sets {
            let capacity = max(set.count, 1)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            if !set.isEmpty {
                set.copyBytes(to: buffer, count: set.count)
            }
            storage.append(buffer)
            pointers.append(UnsafePointer(buffer))
            sizes.append(set.count)
        }

        var description: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(nalLength),
                formatDescriptionOut: &description
            )
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(nalLength),
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr else { return nil }
        return description
    }
}
