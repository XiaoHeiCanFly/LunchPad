import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import QuartzCore
import ScreenCaptureKit
import SwiftUI

struct DockLiveThumbnail: NSViewRepresentable {
    let source: SCWindow
    let snapshot: CGImage?
    let visible: Bool

    func makeNSView(context: Context) -> ThumbnailView {
        ThumbnailView(source: source)
    }

    func updateNSView(_ view: ThumbnailView, context: Context) {
        view.configure(snapshot: snapshot, visible: visible)
    }

    static func dismantleNSView(_ view: ThumbnailView, coordinator: ()) {
        view.stopCapture()
    }

    final class ThumbnailView: NSView {
        private let source: SCWindow
        private let picture = CALayer()
        private var snapshot: CGImage?
        private var visibleInScrollView = false
        private var captureTask: Task<Void, Never>?
        // Keep the displayed buffer out of ScreenCaptureKit's recycling pool.
        private var displayedBuffer: CVPixelBuffer?
        private var showingLiveContent = false

        init(source: SCWindow) {
            self.source = source
            super.init(frame: .zero)
            wantsLayer = true
            picture.contentsGravity = .resizeAspect
            picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(picture)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            picture.frame = bounds
            updateCapture()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateCapture()
        }

        func configure(snapshot: CGImage?, visible: Bool) {
            self.snapshot = snapshot
            visibleInScrollView = visible
            if !showingLiveContent { picture.contents = snapshot }
            updateCapture()
        }

        private func updateCapture() {
            guard visibleInScrollView, let window else {
                stopCapture()
                return
            }
            guard captureTask == nil, bounds.width >= 2, bounds.height >= 2,
                  source.frame.width > 0, source.frame.height > 0 else { return }

            let scale = min(bounds.width / source.frame.width, bounds.height / source.frame.height) * window.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = max(2, Int((source.frame.width * scale).rounded()))
            config.height = max(2, Int((source.frame.height * scale).rounded()))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 4
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
            config.scalesToFit = true
            let filter = SCContentFilter(desktopIndependentWindow: source)
            let (frames, continuation) = AsyncStream<ThumbnailFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let output = ThumbnailOutput(continuation)
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            captureTask = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: ThumbnailOutput.queue)
                    try await stream.startCapture()
                    for await frame in frames {
                        guard !Task.isCancelled else { break }
                        self?.display(frame)
                    }
                    try? await stream.stopCapture()
                } catch {
                    if !Task.isCancelled { ThumbnailOutput.log(error) }
                }
                continuation.finish()
                try? stream.removeStreamOutput(output, type: .screen)
            }
        }

        private func display(_ frame: ThumbnailFrame) {
            showingLiveContent = true
            switch frame {
            case .image(let buffer):
                displayedBuffer = buffer
                picture.backgroundColor = nil
                picture.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            case .blank:
                displayedBuffer = nil
                picture.contents = nil
                picture.backgroundColor = NSColor.black.cgColor
            }
        }

        func stopCapture() {
            captureTask?.cancel()
            captureTask = nil
            showingLiveContent = false
            picture.contents = snapshot
            picture.backgroundColor = nil
            displayedBuffer = nil
        }
    }
}

private nonisolated enum ThumbnailFrame {
    case image(CVPixelBuffer)
    case blank
}

private nonisolated final class ThumbnailOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    static let queue = DispatchQueue(label: "com.king.LunchPad.preview-frames", qos: .userInitiated)
    private let continuation: AsyncStream<ThumbnailFrame>.Continuation

    init(_ continuation: AsyncStream<ThumbnailFrame>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = info.first?[.status] as? Int else { return }
        switch SCFrameStatus(rawValue: rawStatus) {
        case .complete:
            if let buffer = sample.imageBuffer, CVPixelBufferGetIOSurface(buffer) != nil {
                continuation.yield(.image(buffer))
            }
        case .blank:
            continuation.yield(.blank)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish()
        Self.log(error)
    }

    static func log(_ error: Error) {
        let code = (error as NSError).code
        queue.async { LauncherDiagnostics.shared.record("dock-preview", "live-capture-error code=\(code)") }
    }
}
