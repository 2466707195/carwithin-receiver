import AVFoundation
import CoreMedia
import UIKit

/// 视频解码与显示。
///
/// 直接用 `AVSampleBufferDisplayLayer`：CarWithin 送来的是长度前缀的 H.264/H.265 样本，
/// 配合 avcC/hvcC 格式描述就能交给 VideoToolbox 硬解，省掉自己管解码会话和显示链路。
///
/// 时间戳用**本机单调时钟**而不是服务端时间：服务端时间是「开机以来微秒」，
/// 跨设备没有共同基准，直接拿来做 PTS 会让图层以为帧在遥远的未来。
/// 服务端时间只用来算端到端延迟。
final class VideoPipeline {

    let layer = AVSampleBufferDisplayLayer()

    private var formatDescription: CMFormatDescription?
    private(set) var videoSize = CGSize(width: 16, height: 9)
    private(set) var needsKeyframe = true
    private(set) var enqueuedFrames = 0
    private(set) var droppedFrames = 0
    private(set) var decodeFailures = 0

    var lastFrameAt: Date?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.isOpaque = true
    }

    // MARK: - 生命周期

    @discardableResult
    func configure(_ format: CWVideoFormat) -> Bool {
        guard let description = CWFormatDescriptionBuilder.make(format) else { return false }
        formatDescription = description
        videoSize = CGSize(width: format.width, height: format.height)
        needsKeyframe = true
        layer.flush()
        return true
    }

    func reset() {
        formatDescription = nil
        needsKeyframe = true
        lastFrameAt = nil
        layer.flush()
    }

    // MARK: - 送帧

    func enqueue(_ frame: CWVideoFrame) {
        guard let formatDescription else { return }

        if layer.status == .failed {
            decodeFailures += 1
            layer.flush()
            needsKeyframe = true
        }

        if frame.isKeyframe {
            needsKeyframe = false
            if layer.requiresFlushToResumeDecoding {
                layer.flush()
            }
        } else if needsKeyframe {
            // 没有关键帧起头，依赖帧解不出来，直接丢。
            droppedFrames += 1
            return
        }

        if !layer.isReadyForMoreMediaData && !frame.isKeyframe {
            droppedFrames += 1
            return
        }

        guard let buffer = makeSampleBuffer(frame, formatDescription: formatDescription) else {
            droppedFrames += 1
            return
        }

        layer.enqueue(buffer)
        enqueuedFrames += 1
        lastFrameAt = Date()
    }

    // MARK: - CMSampleBuffer

    private func makeSampleBuffer(_ frame: CWVideoFrame, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        let length = frame.sample.count
        guard length > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard created == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = frame.sample.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                blockBuffer: blockBuffer,
                                                offsetIntoDestination: 0,
                                                dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        // 到达即显示：PTS 用本机时钟，等于「现在」。
        let presentation = CMTime(value: Int64(CWClock.micros), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentation,
                                        decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
