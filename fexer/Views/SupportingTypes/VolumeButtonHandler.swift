import AVFoundation
import OSLog
import SwiftUI

/// Blocks spurious AVAudioSession.outputVolume KVO events during audio session
/// setup, interruptions, and camera session reconfiguration.
/// Thread-safe: KVO fires on a background thread, interruption handler may be on any thread.
///
/// Two independent blocking mechanisms:
///   - Time-based (`extend()`) — used at startup and after interruptions.
///   - Counter-based (`block()`/`unblock()`) — used during camera session reconfiguration.
/// The gate is `isReady` only when BOTH mechanisms allow it.
final class VolumeGate: @unchecked Sendable {
    private var notReadyUntil: Date
    private var blockedCount: Int = 0
    private let lock = NSLock()

    init() { notReadyUntil = Date().addingTimeInterval(2.0) }

    func extend() {
        lock.withLock { notReadyUntil = max(notReadyUntil, Date().addingTimeInterval(0.5)) }
    }

    /// Blocks the gate via counter (not time-based). Each `block()` must be matched by one `unblock()`.
    func block() {
        lock.withLock { blockedCount += 1 }
    }

    /// Unblocks one level of counter-based blocking. Safe to call even if `block()` was never called.
    func unblock() {
        lock.withLock {
            if blockedCount > 0 { blockedCount -= 1 }
        }
    }

    var isReady: Bool {
        lock.withLock {
            guard blockedCount == 0 else { return false }
            return Date() >= notReadyUntil
        }
    }
}

extension CameraView {

    func setupVolumeButtonObserver() {
        guard volumeButtonBehavior != "Disabled" else { return }
        let session = AVAudioSession.sharedInstance()
        // .playback without .mixWithOthers gives the best chance of suppressing
        // the system volume HUD (combined with VolumeHUDSuppressor in the hierarchy).
        do {
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            // ponytail: AVCaptureSession owns the audio session in video mode — conflict is benign
            Logger.camera.debug("Audio session setCategory skipped: \(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
        } catch {
            Logger.camera.error("Audio session setActive failed: \(error.localizedDescription)")
        }
        // On first launch, mic/photo-library permission dialogs interrupt the audio session.
        // When each dialog ends, AVAudioSession fires a spurious outputVolume KVO with old != new,
        // which would trigger the shutter. VolumeGate blocks events for 500 ms after setup AND
        // re-arms for 500 ms each time an interruption ends, covering the whole permission flow.
        let gate = volumeGate
        gate.extend()
        volumeInterruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: type) == .ended else { return }
            gate.extend()
            // Retry activation after interruption — the initial attempt may have failed
            // if permission dialogs were competing for the audio hardware (err=-19224).
            try? session.setActive(true)
        }
        volumeRouteChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { _ in gate.extend() }
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { _, change in
            guard gate.isReady else { return }
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            Task { @MainActor in self.handleVolumeButton(didIncrease: new > old) }
        }
    }

    func handleVolumeButton(didIncrease: Bool) {
        switch volumeButtonBehavior {
        case "Shutter":
            captureAction()
        case "Zoom":
            let delta: CGFloat = didIncrease ? 0.5 : -0.5
            let newZoom = (cameraViewModel.zoomLevel + delta).fxClamped(to: 0.5...15.0)
            cameraViewModel.handlePinchZoom(scale: newZoom, velocity: 0)
        default:
            break
        }
    }
}
