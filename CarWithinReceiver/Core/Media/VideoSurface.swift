import SwiftUI
import UIKit

/// 视频画面 + 触摸回传。
///
/// 触摸要**原样转给 CarPlay**：这里不做任何手势识别，只把多指位置归一化后发出去，
/// 缩放、旋转、双指滑动都靠 CarPlay 自己处理。
struct VideoSurface: UIViewRepresentable {

    let pipeline: VideoPipeline
    var videoSize: CGSize
    var onTouches: ([CWTouchPoint]) -> Void
    var onActivity: () -> Void

    func makeUIView(context: Context) -> TouchVideoView {
        let view = TouchVideoView()
        view.videoSize = videoSize
        view.onTouches = onTouches
        view.onActivity = onActivity
        view.attach(pipeline)
        return view
    }

    func updateUIView(_ uiView: TouchVideoView, context: Context) {
        uiView.videoSize = videoSize
        uiView.onTouches = onTouches
        uiView.onActivity = onActivity
        uiView.attach(pipeline)
    }
}

final class TouchVideoView: UIView {

    var videoSize: CGSize = CGSize(width: 16, height: 9)
    var onTouches: (([CWTouchPoint]) -> Void)?
    var onActivity: (() -> Void)?

    private weak var attached: VideoPipeline?
    private var fingerIDs: [ObjectIdentifier: Int] = [:]
    private var points: [Int: CGPoint] = [:]
    private var nextFingerID = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isOpaque = true
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 图层

    func attach(_ pipeline: VideoPipeline) {
        guard attached !== pipeline else { return }
        attached?.layer.removeFromSuperlayer()
        pipeline.layer.frame = bounds
        layer.addSublayer(pipeline.layer)
        attached = pipeline
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attached?.layer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onActivity?()
        for touch in touches {
            guard fingerIDs.count < 10 else { break }
            let id = allocateFingerID()
            fingerIDs[ObjectIdentifier(touch)] = id
            if let point = normalized(touch.location(in: self)) {
                points[id] = point
            }
        }
        emit()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = fingerIDs[ObjectIdentifier(touch)] else { continue }
            if let point = normalized(touch.location(in: self)) {
                points[id] = point
            }
        }
        emit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let id = fingerIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            points.removeValue(forKey: id)
        }
        emit()
    }

    private func allocateFingerID() -> Int {
        var candidate = nextFingerID
        var guardCount = 0
        while points[candidate] != nil || fingerIDs.values.contains(candidate) {
            candidate = (candidate + 1) & 0xFF
            guardCount += 1
            if guardCount > 255 { break }
        }
        nextFingerID = (candidate + 1) & 0xFF
        return candidate
    }

    private func emit() {
        let list = points
            .sorted { $0.key < $1.key }
            .map { CWTouchPoint(id: $0.key, x: Double($0.value.x), y: Double($0.value.y)) }
        onTouches?(list)
    }

    /// 画面按 `.resizeAspect` 居中显示，触摸点要换算成这块内容矩形里的 0…1 坐标。
    private func normalized(_ point: CGPoint) -> CGPoint? {
        let area = bounds
        guard area.width > 1, area.height > 1 else { return nil }
        let videoWidth = max(videoSize.width, 1)
        let videoHeight = max(videoSize.height, 1)
        let scale = min(area.width / videoWidth, area.height / videoHeight)
        let width = videoWidth * scale
        let height = videoHeight * scale
        guard width > 0, height > 0 else { return nil }
        let originX = (area.width - width) / 2
        let originY = (area.height - height) / 2
        let x = (point.x - originX) / width
        let y = (point.y - originY) / height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
