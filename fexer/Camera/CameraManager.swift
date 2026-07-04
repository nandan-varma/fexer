import AVFoundation
import CoreImage
import CoreLocation
import Observation
import OSLog
import Foundation
import UIKit
import Photos

    /// Owns the AVCaptureSession and all camera hardware configuration.
    /// @Observable properties are read from MainActor; all session mutations
    /// are dispatched to sessionQueue for thread safety.
    @Observable
    final class CameraManager: NSObject {
    // MARK: - Published state (MainActor)
    var isSessionRunning = false
    var currentISO: Float = 200
    var currentShutterSpeed: CMTime = CMTime(value: 1, timescale: 250)
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

    // MARK: - Internal (sessionQueue only)
    let processor = CaptureProcessor()
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "com.fexer.session", qos: .userInteractive)
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
    var videoWriterInput: AVAssetWriterInput?
    @ObservationIgnored nonisolated(unsafe) var audioWriterInput: AVAssetWriterInput?
    var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    var isWaitingToRecord = false
    var pendingRecordingLocation: CLLocation?
    var pendingRecordingStyleName: String?

    // Busy guard for still capture — checked and set atomically on sessionQueue to prevent TOCTOU.
    // isCapturing mirrors this on MainActor for UI binding.
    var _captureBusy = false
    // WB bracket fires N separate capturePhoto calls sharing one delegate.
    // clearCaptureGuard only truly clears when all expected completions arrive.
    var pendingBracketCompletions = 0

    // KVO observation tokens are created and invalidated exclusively on sessionQueue.
    var deviceObservations: [NSKeyValueObservation] = []
    var subjectAreaObserver: NSObjectProtocol?

    // Timer runs on MainActor; kept here so we can invalidate from MainActor context
    var recordingTimer: Timer?

    // Device model string read once on init (MainActor) so it's safe to access from sessionQueue.
    let deviceModel: String = UIDevice.current.model

    var captureSettings = CaptureSettings()

    @ObservationIgnored lazy var iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Notification observation tokens

    private var sessionErrorObserver: NSObjectProtocol?
    private var sessionInterruptionObserver: NSObjectProtocol?
    private var sessionInterruptionEndedObserver: NSObjectProtocol?

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
            [sessionErrorObserver, sessionInterruptionObserver, sessionInterruptionEndedObserver]
                .compactMap { $0 }
                .forEach { NotificationCenter.default.removeObserver($0) }
            sessionErrorObserver = nil
            sessionInterruptionObserver = nil
            sessionInterruptionEndedObserver = nil
            cleanupObservers()
            processor.isRotationReady = false
            self.session.stopRunning()
            Task { @MainActor in self.isSessionRunning = false }
        }
    }

    deinit {
        [sessionErrorObserver, sessionInterruptionObserver, sessionInterruptionEndedObserver]
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

        guard let device = Self.bestCamera(for: .back),
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
            $0.isVideoHDRSupported
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
            guard let device = Self.bestCamera(for: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else {
                Logger.camera.error("Failed to flip camera: cannot access device at position \(newPosition.rawValue)")
                return
            }

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
            }
            cleanupObservers()
            setupObservations(for: device)
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                configureVideoRotation()
                processor.isRotationReady = true
            }
        }
    }
}

// MARK: - Device selection

extension CameraManager {
    /// Returns the best color camera for the given position by querying the hardware.
    static func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let physicalTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
        ]
        let virtualTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
        ]
        let allTypes = physicalTypes + virtualTypes
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: allTypes, mediaType: .video, position: position
        ).devices
        for type in physicalTypes {
            if let d = devices.first(where: { $0.deviceType == type }) { return d }
        }
        return devices.first
    }
}

// MARK: - Supporting Types

struct LensOption: Identifiable {
    let id = UUID()
    let device: AVCaptureDevice
    let label: String
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
