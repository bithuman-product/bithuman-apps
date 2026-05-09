// AvatarPiPController — drives a Picture-in-Picture floating window
// of the avatar that hovers over other iPad apps. Uses the iOS 15+
// `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:
// playbackDelegate:)` API so we can feed our own per-frame CGImages
// instead of an AVPlayer-backed video file.
//
// Architecture:
//   FramePump.consumer  →  render(_: CGImage)
//                              ↓
//                   convert to CMSampleBuffer
//                              ↓
//                   AVSampleBufferDisplayLayer.enqueue(_:)
//                              ↓
//                   AVPictureInPictureController.ContentSource
//                              ↓
//                   user taps "Float" → startPictureInPicture()
//
// Conforms to AvatarFrameSink so the existing FramePump dispatch path
// drives both this controller and the on-screen renderer in lockstep
// (via MultiAvatarFrameSink in BithumanPadLifecycle).

#if canImport(UIKit)
import AVFoundation
import AVKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import UIKit

@MainActor
public final class AvatarPiPController: NSObject, ObservableObject {

    /// Posted once the system PiP window is actually on screen. iPad
    /// app's scene delegate listens to collapse the main window's
    /// size restrictions so only the PiP circle remains visible.
    public static let didStartNotification = Notification.Name("ai.bithuman.AvatarPiPController.didStart")
    /// Posted when the PiP window is dismissed (via close X or
    /// restore, before sticky bounces it back). Scene delegate
    /// restores the main window's normal size.
    public static let didStopNotification = Notification.Name("ai.bithuman.AvatarPiPController.didStop")


    /// True while the system is rendering the floating PiP window —
    /// iPad apps observe this to hide their main UI (paint Color.clear)
    /// and let the iPadOS desktop show through, leaving only the PiP
    /// circle visible.
    @Published public private(set) var isActive: Bool = false


    /// The display layer that owns the PiP content. Hosted inside
    /// `hostView` below — AVPictureInPictureController requires the
    /// SDL to be in the live view tree (a UIView that's in a
    /// UIWindow) before `isPictureInPicturePossible` flips to true.
    public let displayLayer = AVSampleBufferDisplayLayer()

    /// Invisible UIView that hosts `displayLayer`. The iPad app adds
    /// this to the SwiftUI hierarchy as a 1×1 hidden overlay — the
    /// system PiP renders the SDL content in its own floating
    /// window, but the source layer must still be parented under a
    /// live window for the controller to function.
    public let hostView: UIView = {
        let v = UIView(frame: .zero)
        v.isHidden = false  // `false` so the layer keeps drawing — opacity 0 instead
        v.alpha = 0
        v.isUserInteractionEnabled = false
        return v
    }()

    /// PiP controller. iOS only enables PiP when this controller's
    /// `isPictureInPicturePossible` flips to true, which happens
    /// after the SDL has at least one buffer enqueued AND the
    /// containing view is in the window hierarchy. Hold a strong
    /// reference for the lifetime of the session.
    public private(set) var pipController: AVPictureInPictureController?

    /// Source resolution. The 384×384 avatar engine output is what we
    /// feed; PiP windowing scales independently.
    private let frameWidth: Int = 384
    private let frameHeight: Int = 384
    private let videoFPS: Int32 = 25

    /// Monotonic frame counter for PTS. PiP rejects sample buffers
    /// whose presentation time isn't strictly increasing.
    private var nextFrameIndex: Int64 = 0

    /// When true, `enqueue` calls `startPiP()` after the SDL has been
    /// fed a handful of frames and the controller flips
    /// `isPictureInPicturePossible`. Used to auto-pop the avatar into
    /// a corner PiP window on launch instead of dwelling in the full
    /// app. Set by the iPad app via `enableAutoStart()`.
    private var autoStartArmed: Bool = false
    private var autoStartFiredOnce: Bool = false

    /// "Sticky" PiP — when the system PiP UI is dismissed (close X
    /// button or restore-to-app icon tapped), the controller re-
    /// enters PiP after a short delay so the avatar always floats.
    /// Used on iPad to lock the experience to PiP. Set by the iPad
    /// app via `setSticky(true)`.
    private var sticky: Bool = false

    /// Cached pixel-buffer pool — allocating a fresh CVPixelBuffer per
    /// frame at 25 FPS thrashes the allocator. The pool reuses buffers.
    private var pixelBufferPool: CVPixelBufferPool?

    private var formatDescription: CMVideoFormatDescription?

    public override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        hostView.layer.addSublayer(displayLayer)
        hostView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            NSLog("[AvatarPiP] PiP not supported on this device")
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // True so the system also auto-pops PiP when the user
        // backgrounds the app — together with `enableAutoStart()`,
        // the avatar always ends up in a floating corner window.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller
    }

    // MARK: - Frame intake

    /// Push a frame from the FramePump. Converts CGImage → CVPixelBuffer
    /// → CMSampleBuffer with a monotonic PTS, then enqueues. No-op if
    /// PiP isn't supported (graceful degradation on older devices).
    public func enqueue(_ image: CGImage) {
        guard let pip = pipController else { return }
        guard let sampleBuffer = makeSampleBuffer(image: image) else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)

        // Auto-start: as soon as the controller flips
        // `isPictureInPicturePossible` (typically after a handful of
        // enqueued frames AND the host view is in the window
        // hierarchy), pop into PiP. Fires once.
        if autoStartArmed && !autoStartFiredOnce && nextFrameIndex >= 6 {
            if pip.isPictureInPicturePossible {
                autoStartFiredOnce = true
                pip.startPictureInPicture()
            }
        }
    }

    // MARK: - Auto-start + sticky configuration

    /// Arm auto-start: the next time `enqueue` finds
    /// `isPictureInPicturePossible == true`, the controller activates
    /// PiP automatically. Idempotent; called from the iPad app right
    /// after construction.
    public func enableAutoStart() {
        autoStartArmed = true
    }

    /// Lock the experience to PiP — every dismiss (close X, restore-
    /// to-app icon) re-enters PiP after a 0.4 s delay. Pass `false` to
    /// release the lock if the app needs to reach the full UI for an
    /// admin gesture.
    public func setSticky(_ on: Bool) {
        sticky = on
    }

    // MARK: - PiP control

    /// Start floating the avatar over other iPad apps. Must be called
    /// in response to a user gesture; iOS rejects unsolicited PiP
    /// activation (returns false in `isPictureInPicturePossible`).
    public func startPiP() {
        guard let pip = pipController else {
            NSLog("[AvatarPiP] PiP not available")
            return
        }
        if !pip.isPictureInPicturePossible {
            // Most common cause: SDL has no enqueued buffers yet, or
            // the host view isn't in the window hierarchy. The caller
            // has to ensure both before requesting start.
            NSLog("[AvatarPiP] PiP not yet possible — needs at least one frame and a live view tree")
            return
        }
        pip.startPictureInPicture()
    }

    public func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    // MARK: - CGImage → CMSampleBuffer

    private func makeSampleBuffer(image: CGImage) -> CMSampleBuffer? {
        guard let pool = ensurePool() else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))

        let formatDesc = ensureFormatDescription(pixelBuffer: pixelBuffer)
        guard let formatDesc else { return nil }

        let pts = CMTime(value: nextFrameIndex, timescale: videoFPS)
        nextFrameIndex &+= 1
        let duration = CMTime(value: 1, timescale: videoFPS)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }

        // Mark sample as displayable immediately — the live stream has
        // no decoder dependency chain.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private func ensurePool() -> CVPixelBufferPool? {
        if let pool = pixelBufferPool { return pool }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: frameWidth,
            kCVPixelBufferHeightKey: frameHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { return nil }
        pixelBufferPool = pool
        return pool
    }

    private func ensureFormatDescription(pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        if let cached = formatDescription { return cached }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &desc
        )
        guard status == noErr, let desc else { return nil }
        formatDescription = desc
        return desc
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
// Live, infinite "video" — no scrubbing, no pause / resume, no
// timeline. PiP just renders whatever frames we enqueue.
extension AvatarPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // No-op: the avatar engine is the source of truth for whether
        // there's content to show. We don't pause it from PiP UI.
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Live content. Apple's recommended convention for "no
        // timeline" is `(.negativeInfinity, .positiveInfinity)`.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // Could track for adaptive resolution; we render at 384² and
        // the system handles scaling.
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        // No skip support for live content.
        completionHandler()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension AvatarPiPController: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_: AVPictureInPictureController) {
        NSLog("[AvatarPiP] willStart")
    }
    public func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        NSLog("[AvatarPiP] didStart")
        isActive = true
        NotificationCenter.default.post(name: AvatarPiPController.didStartNotification, object: self)
    }
    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        NSLog("[AvatarPiP] failed to start: \(error)")
    }
    public func pictureInPictureControllerWillStopPictureInPicture(_: AVPictureInPictureController) {
        NSLog("[AvatarPiP] willStop")
    }
    public func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        NSLog("[AvatarPiP] didStop")
        isActive = false
        NotificationCenter.default.post(name: AvatarPiPController.didStopNotification, object: self)
        // Sticky mode: bounce straight back into PiP. Small delay so
        // the system's stop animation has a moment to commit before
        // we re-request — calling start in the same frame as didStop
        // is rejected as "not possible".
        if sticky {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.pipController?.startPictureInPicture()
            }
        }
    }
}

// MARK: - AvatarFrameSink — lets FramePump drive PiP via the same
// dispatch path as the on-screen renderer (through MultiAvatarFrameSink).
extension AvatarPiPController: AvatarFrameSink {
    public func render(_ frame: CGImage) {
        enqueue(frame)
    }
}

#endif // canImport(UIKit)
