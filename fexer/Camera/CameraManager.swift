// swiftlint:disable file_length
import AVFoundation
import CoreImage
import CoreLocation
import Foundation
import Observation
import OSLog
import Photos
import UIKit

    /// Owns the AVCaptureSession and all camera hardware configuration.
    /// @Observable properties are read from MainActor; all session mutations
    /// are dispatched to sessionQueue for thread safety.
    @Observable
    final class CameraManager: NSObject {
    // MARK: - Published state (MainActor)
    var isSessionRunning = false
    var currentISO: Float = 200
    var currentShutterSpeed = CMTime(value: 1, timescale: 250)
    var currentWhiteBalance: Float = 5500
    var currentLensPosition: Float = 0.5
    var currentWhiteBalanceTint: Float = 0
    var currentZoomFactor: CGFloat = 1.0
    var flashMode: AVCaptureDevice.FlashMode = .off
    var isCapturing = false
    var lastCapturedPhoto: CapturedPhoto?
    var previewImageSize: CGSize = .zero

    // Video recording state (MainActor)
    var isRecording = false
    // True once the prebuilt writer is ready; false while it's still building (shows spinner).
    var isVideoWriterReady = false
    var recordingDuration: TimeInterval = 0

    // Live Photo toggle (MainActor)
    var isLivePhotoEnabled = false

    // Hardware capability flags (set after session configuration)
    var isProRAWSupported: Bool = false
    var isDepthDataSupported: Bool = false
    var isAppleLogSupported: Bool = false
    var isHDRFormatSupported: Bool = false
    var isSlowMotionSupported: Bool = false
    var maxSlowMotionFPS: Int = 60
    var supportsManualFocus: Bool = false
    var supportsCustomExposure: Bool = false

    // Live audio level (updated ~10fps while recording, 0.0=silence 1.0=peak)
    var audioLevel: Float = 0.0

    // Physical cameras discovered on device (populated at session start, updated on plug/unplug).
    var discoveredCameras: [AVCaptureDevice] = []

    // Back-camera lens options derived from the virtual device's constituent map.
    // Populated once at session start; empty on front camera.
    var backLenses: [LensOption] = []
    // Optical magnification of the currently active physical lens relative to wide-angle (1×).
    // e.g. 0.5 for ultra-wide, 1.0 for wide, 3.0 for telephoto.
    var activeLensOpticalFactor: CGFloat = 1.0

    // MARK: - Internal (sessionQueue only)
    let processor = CaptureProcessor()
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "com.fexer.session", qos: .userInteractive)
    // Writer setup (AVAssetWriter creation + startWriting) runs here so sessionQueue
    // (and captureOutput / the live preview) is never blocked during encoder init.
    let writerSetupQueue = DispatchQueue(label: "com.fexer.writerSetup", qos: .userInitiated)
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    private(set) var currentDevice: AVCaptureDevice?
    var trapFocusCaptureCallback: (() -> Void)?
    private var sessionGeneration: UInt64 = 0

    // AVAssetWriter recording pipeline — accessed from sessionQueue AND nonisolated audio delegate.
    // All mutations are serialised through sessionQueue; @ObservationIgnored + nonisolated(unsafe)
    // lets the nonisolated AVCaptureAudioDataOutputSampleBufferDelegate read them without warnings.
    @ObservationIgnored nonisolated(unsafe) var assetWriter: AVAssetWriter?
    @ObservationIgnored nonisolated(unsafe) var videoWriterInput: AVAssetWriterInput?
    @ObservationIgnored nonisolated(unsafe) var audioWriterInput: AVAssetWriterInput?
    @ObservationIgnored nonisolated(unsafe) var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored nonisolated(unsafe) var isWaitingToRecord = false
    @ObservationIgnored nonisolated(unsafe) var pendingRecordingLocation: CLLocation?
    @ObservationIgnored nonisolated(unsafe) var pendingRecordingStyleName: String?
    // True between stopRecording clearing the writer vars and finishWriting completing.
    // Gates startRecording so a new writer can't start while the old one is still flushing.
    @ObservationIgnored nonisolated(unsafe) var isFinishingRecording = false
    // Pre-built writer stored between mode-switch and record tap. When settings match,
    // startRecording installs it directly (0ms startWriting overhead). sessionQueue only.
    @ObservationIgnored nonisolated(unsafe) var prebuiltWriterEntry: PrebuiltWriterEntry?
    // True while schedulePrebuiltWriter is building on writerSetupQueue.
    // startRecording sets pendingRecordOnPrebuiltComplete instead of queuing a second build.
    @ObservationIgnored nonisolated(unsafe) var isPrebuiltBuilding = false
    // Set by startRecording when it arrives while a prebuilt is still building.
    // The prebuilt's sessionQueue hop-back calls this closure to install the writer.
    @ObservationIgnored nonisolated(unsafe) var pendingRecordOnPrebuiltComplete: ((CameraManager.WriterComponents) -> Void)?

    // Saved before HDR format switch so disabling HDR can restore the original format.
    @ObservationIgnored nonisolated(unsafe) var preHDRFormat: AVCaptureDevice.Format?

    // Busy guard for still capture — checked and set atomically on sessionQueue to prevent TOCTOU.
    // isCapturing mirrors this on MainActor for UI binding.
    @ObservationIgnored nonisolated(unsafe) var _captureBusy = false
    // WB bracket fires N separate capturePhoto calls sharing one delegate.
    // clearCaptureGuard only truly clears when all expected completions arrive.
    @ObservationIgnored nonisolated(unsafe) var pendingBracketCompletions = 0

    // Non-nil when a recording failed mid-capture (e.g. disk full). Cleared on next recording start.
    var recordingError: Error?

    // Counter for throttling audio-level MainActor updates to ~10fps. sessionQueue only.
    @ObservationIgnored nonisolated(unsafe) var audioSampleCount: Int = 0

    // KVO observation tokens are created and invalidated exclusively on sessionQueue.
    var deviceObservations: [NSKeyValueObservation] = []
    var subjectAreaObserver: NSObjectProtocol?

    // Timer runs on MainActor; kept here so we can invalidate from MainActor context
    var recordingTimer: Timer?

    // Device model string read once on init (MainActor) so it's safe to access from sessionQueue.
    let deviceModel: String = UIDevice.current.model

    var captureSettings = CaptureSettings()

    @ObservationIgnored lazy var iso8601Formatter = ISO8601DateFormatter()

    // Called on MainActor before/after every session beginConfiguration/commitConfiguration pair.
    // CameraView wires these to volumeGate.block() / volumeGate.unblock() so that spurious
    // AVAudioSession.outputVolume KVO events triggered by session reconfiguration are suppressed.
    var onVolumeGateWillBlock: (() -> Void)?
    var onVolumeGateDidUnblock: (() -> Void)?

    // MARK: - Notification observation tokens

    private var sessionErrorObserver: NSObjectProtocol?
    private var sessionInterruptionObserver: NSObjectProtocol?
    private var sessionInterruptionEndedObserver: NSObjectProtocol?
    private var cameraConnectObserver: NSObjectProtocol?
    private var cameraDisconnectObserver: NSObjectProtocol?

    // MARK: - Setup

    func startSession() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            self.configureSession()
            self.session.startRunning()
            Task { @MainActor in self.isSessionRunning = true }
            // Observe runtime errors for session recovery (correct notification name).
            self.sessionErrorObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleSessionError(notification)
            }
            // Stop recording cleanly when a phone call, Siri, or other system event interrupts.
            self.sessionInterruptionObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                // stopRecording internally dispatches to sessionQueue — safe to call from any thread.
                if self.isRecording || self.isWaitingToRecord { self.stopRecording() }
            }
            // Restart after interruptions (permission dialogs, phone calls, background, etc.)
            self.sessionInterruptionEndedObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                sessionQueue.async {
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    // Re-apply rotation in case connection was reset during interruption.
                    self.configureVideoRotation()
                    self.processor.isRotationReady = true
                    Task { @MainActor in self.isSessionRunning = self.session.isRunning }
                }
            }
            // Observe physical camera availability changes (external/Continuity Camera plug/unplug).
            self.cameraConnectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshDiscoveredCameras() }
            self.cameraDisconnectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshDiscoveredCameras() }

            // Defer video rotation so the connection stabilises after startRunning.
            // Setting videoRotationAngle immediately can trigger Fig err=-12710.
            // Frames are dropped until this fires (isRotationReady gate in CaptureProcessor).
            let gen = sessionGeneration
            self.sessionQueue.asyncAfter(deadline: .now() + 0.30) { [self] in
                guard gen == sessionGeneration else { return }
                self.configureVideoRotation()
                self.processor.isRotationReady = true
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [self] in
            sessionGeneration &+= 1
            [sessionErrorObserver, sessionInterruptionObserver, sessionInterruptionEndedObserver,
             cameraConnectObserver, cameraDisconnectObserver]
                .compactMap { $0 }
                .forEach { NotificationCenter.default.removeObserver($0) }
            sessionErrorObserver = nil
            sessionInterruptionObserver = nil
            sessionInterruptionEndedObserver = nil
            cameraConnectObserver = nil
            cameraDisconnectObserver = nil
            cleanupObservers()
            processor.isRotationReady = false
            self.session.stopRunning()
            Task { @MainActor in self.isSessionRunning = false }
        }
    }

    deinit {
        [sessionErrorObserver, sessionInterruptionObserver, sessionInterruptionEndedObserver,
         cameraConnectObserver, cameraDisconnectObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
        subjectAreaObserver.map { NotificationCenter.default.removeObserver($0) }
        if let t = recordingTimer { t.invalidate() }
        recordingTimer = nil
    }

    @objc private func handleSessionError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else { return }
        Logger.camera.error("Session runtime error: \(error.localizedDescription) (domain=\(error.domain) code=\(error.code))")

        if error.code == -12710 {
            Logger.camera.warning("err=-12710 suggests a connection/rotation configuration mismatch. Re-applying rotation in 0.5s.")
            sessionQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
                configureVideoRotation()
            }
        }

        sessionQueue.asyncAfter(deadline: .now() + 1.0) { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
            Task { @MainActor in self.isSessionRunning = session.isRunning }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // Build back-lens map from virtual device (discovery only — never added to session).
        buildBackLensMap()

        // Always start on the physical wide-angle camera so every manual control works.
        // Virtual multi-lens devices (triple/dual) block manual focus and exposure.
        let startDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device = startDevice ?? Self.physicalCamera(for: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            Logger.camera.error("configureSession: failed to access back camera or create device input")
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) { session.addInput(input) }
        currentDevice = device

        videoOutput.setSampleBufferDelegate(processor, queue: sessionQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Audio output for AVAssetWriter pipeline
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // Live Photo requires the capture to be enabled before commitConfiguration
        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = true
        }

        // Microphone input for video recording audio
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        session.commitConfiguration()

        let appleLogOK = device.formats.contains {
            $0.supportedColorSpaces.contains(.appleLog)
        }
        let hdrOK = device.formats.contains {
            $0.isVideoHDRSupported || $0.supportedColorSpaces.contains(.HLG_BT2020)
        }
        let slowMoFPS = device.formats
            .flatMap { $0.videoSupportedFrameRateRanges }
            .filter { $0.maxFrameRate > 60 }
            .map { Int($0.maxFrameRate) }
            .max() ?? 0
        Task { @MainActor in
            self.isProRAWSupported = photoOutput.isAppleProRAWSupported
            self.isDepthDataSupported = photoOutput.isDepthDataDeliverySupported
            self.isAppleLogSupported = appleLogOK
            self.isHDRFormatSupported = hdrOK
            self.isSlowMotionSupported = slowMoFPS > 60
            self.maxSlowMotionFPS = max(60, slowMoFPS)
            self.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
            self.supportsCustomExposure = device.isExposureModeSupported(.custom)
        }

        setupObservations(for: device)

        processor.onPreviewSizeKnown = { [weak self] size in
            Task { @MainActor in self?.previewImageSize = size }
        }

        refreshDiscoveredCameras()
    }

    // MARK: - Video Rotation

    /// Tells AVFoundation to deliver portrait-upright frames to the video output.
    /// Must be called on sessionQueue, after session.commitConfiguration().
    func configureVideoRotation() {
        let portraitAngle: CGFloat = 90
        if let conn = videoOutput.connection(with: .video),
           conn.isVideoRotationAngleSupported(portraitAngle) {
            conn.videoRotationAngle = portraitAngle
        }
    }

    // MARK: - Flip Camera

    func flipCamera() {
        sessionQueue.async { [self] in
            let currentPosition = currentDevice?.position ?? .back
            let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back

            // Back: restore physical wide-angle (manual controls work; lens switcher handles discrete switching).
            // Front: use the physical front camera (TrueDepth or wide-angle, both physical).
            let targetDevice: AVCaptureDevice?
            if newPosition == .back {
                targetDevice = backLenses.first(where: { $0.opticalFactor == 1.0 })?.device
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? Self.physicalCamera(for: .back)
            } else {
                targetDevice = Self.bestCamera(for: .front)
            }

            guard let device = targetDevice,
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else {
                Logger.camera.error("Failed to flip camera: cannot access device at position \(newPosition.rawValue)")
                return
            }

            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) {
                session.removeInput(input)
            }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            // Re-add microphone — removing all inputs above strips it too.
            if let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioIn = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioIn) {
                session.addInput(audioIn)
            }
            currentDevice = device
            processor.isRotationReady = false
            session.commitConfiguration()
            Task { @MainActor in
                self.isDepthDataSupported = photoOutput.isDepthDataDeliverySupported
                self.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
                self.supportsCustomExposure = device.isExposureModeSupported(.custom)
                self.activeLensOpticalFactor = newPosition == .back ? 1.0 : 1.0
                self.currentZoomFactor = 1.0
            }
            cleanupObservers()
            setupObservations(for: device)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
                processor.isRotationReady = true
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }
}

// MARK: - Device selection

extension CameraManager {

    // MARK: - Device selection

    /// Best camera for front position: TrueDepth → wide-angle.
    /// For back position when specifically needed as a fallback.
    static func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTrueDepthCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices.first
    }

    /// Returns the physical wide-angle camera for a position (never a virtual device).
    static func physicalCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices.first
    }

    // MARK: - Back lens map (built once from virtual device, discovery only)

    /// Queries whichever virtual multi-lens device is present, extracts its constituent
    /// physical cameras and computes their optical factors relative to wide-angle = 1×.
    /// The virtual device is never added to the capture session.
    func buildBackLensMap() {
        let virtualTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        guard let virtual = virtualTypes.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
              !virtual.constituentDevices.isEmpty else {
            // Single back camera
            if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                Task { @MainActor [weak self] in
                    self?.backLenses = [LensOption(device: wide, label: "1×", opticalFactor: 1.0)]
                }
            }
            return
        }
        let constituents = virtual.constituentDevices
        let rawFactors = [virtual.minAvailableVideoZoomFactor]
            + virtual.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        // Wide-angle raw factor = the reference (= optical 1×)
        let mainIdx = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) ?? 0
        let mainRaw: CGFloat = mainIdx < rawFactors.count ? rawFactors[mainIdx] : 1.0

        let lenses = zip(constituents, rawFactors).map { device, rawFactor -> LensOption in
            let optical = rawFactor / mainRaw
            return LensOption(device: device, label: Self.opticalLabel(optical), opticalFactor: optical)
        }
        Task { @MainActor [weak self] in self?.backLenses = lenses }
    }

    // MARK: - Lens switching

    /// Switches the capture session to a different physical back camera.
    /// Updates `activeLensOpticalFactor` and resets digital zoom to 1×.
    func switchToCamera(_ lens: LensOption) {
        sessionQueue.async { [self] in
            let device = lens.device
            guard let newInput = try? AVCaptureDeviceInput(device: device) else {
                Logger.camera.error("switchToCamera: cannot create input for \(device.localizedName)")
                return
            }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                where input.device.hasMediaType(.video) {
                session.removeInput(input)
            }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            currentDevice = device
            processor.isRotationReady = false
            session.commitConfiguration()
            Task { @MainActor in
                self.activeLensOpticalFactor = lens.opticalFactor
                self.currentZoomFactor = 1.0
                self.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
                self.supportsCustomExposure = device.isExposureModeSupported(.custom)
                self.isDepthDataSupported = self.photoOutput.isDepthDataDeliverySupported
            }
            cleanupObservers()
            setupObservations(for: device)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
                processor.isRotationReady = true
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    // MARK: - Portrait mode device switching

    /// Switches to the best virtual back camera that supports depth data delivery.
    /// Physical cameras return false for isDepthDataDeliverySupported on Pro models —
    /// depth fusion (LiDAR + camera) is only exposed through virtual devices.
    func switchToDepthCapableCamera() {
        sessionQueue.async { [self] in
            guard !photoOutput.isDepthDataDeliverySupported else { return }
            guard currentDevice?.position == .back else { return }
            let virtualTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
            guard let virtual = virtualTypes.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
                  let newInput = try? AVCaptureDeviceInput(device: virtual) else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) where input.device.hasMediaType(.video) {
                session.removeInput(input)
            }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            currentDevice = virtual
            processor.isRotationReady = false
            session.commitConfiguration()
            Task { @MainActor in self.isDepthDataSupported = self.photoOutput.isDepthDataDeliverySupported }
            cleanupObservers()
            setupObservations(for: virtual)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
                processor.isRotationReady = true
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    /// Restores the physical wide-angle back camera after portrait mode.
    func restorePhysicalBackCamera() {
        sessionQueue.async { [self] in
            guard let current = currentDevice, !current.constituentDevices.isEmpty else { return }
            let wide = backLenses.first(where: { $0.opticalFactor == 1.0 })?.device
                ?? Self.physicalCamera(for: .back)
            guard let wide, let newInput = try? AVCaptureDeviceInput(device: wide) else { return }
            Task { @MainActor in self.onVolumeGateWillBlock?() }
            session.beginConfiguration()
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) where input.device.hasMediaType(.video) {
                session.removeInput(input)
            }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            currentDevice = wide
            processor.isRotationReady = false
            session.commitConfiguration()
            Task { @MainActor in
                self.isDepthDataSupported = self.photoOutput.isDepthDataDeliverySupported
                self.supportsManualFocus = wide.isLockingFocusWithCustomLensPositionSupported
                self.supportsCustomExposure = wide.isExposureModeSupported(.custom)
            }
            cleanupObservers()
            setupObservations(for: wide)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
                processor.isRotationReady = true
                Task { @MainActor in self.onVolumeGateDidUnblock?() }
            }
        }
    }

    // MARK: - Camera discovery

    func refreshDiscoveredCameras() {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
            .builtInTrueDepthCamera, .builtInLiDARDepthCamera
        ]
        if #available(iOS 17, *) { types += [.external, .continuityCamera] }
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
        Task { @MainActor [weak self] in self?.discoveredCameras = cameras }
    }

    static func maxSupportedFPS(for device: AVCaptureDevice) -> Int {
        device.formats.flatMap { $0.videoSupportedFrameRateRanges }.map { Int($0.maxFrameRate) }.max() ?? 30
    }

    // MARK: - Optical label helpers

    static func opticalLabel(_ optical: CGFloat) -> String {
        if optical < 1.0 {
            let s = String(format: "%g", optical)
            let trimmed = s.hasPrefix("0") ? String(s.dropFirst()) : s
            return trimmed + "×"
        }
        let r = (optical * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))×" }
        return String(format: "%.1f×", r)
    }
}

// MARK: - Supporting Types

struct LensOption: Identifiable {
    let id = UUID()
    let device: AVCaptureDevice
    let label: String
    let opticalFactor: CGFloat  // relative to wide-angle = 1× (e.g. 0.5 for ultra-wide, 3.0 for telephoto)
}

// MARK: - Comparable extensions

extension Comparable {
    func fxClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - AVCaptureDevice lock helper

extension AVCaptureDevice {
    func withLock(_ body: () -> Void) {
        do {
            try lockForConfiguration()
            defer { unlockForConfiguration() }
            body()
        } catch {
            Logger.camera.error("lockForConfiguration failed: \(error.localizedDescription)")
        }
    }
}
