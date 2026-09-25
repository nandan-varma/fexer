import AVFoundation

/// Field logs showed adding a microphone `AVCaptureDeviceInput` to *any* `AVCaptureSession` for
/// the first time in a process forces iOS to negotiate the audio hardware route: ~4.2s exactly
/// once per launch, then under 350ms on every later video-mode entry, regardless of session or
/// even switching back to photo mode in between. Priming it here — on a disposable session that
/// never runs and has nothing to do with `CameraService` — means the live camera actor never
/// queues a real capture behind this one-time tax.
///
/// Never requests microphone permission itself: asking before the user has shown any video
/// intent (just from opening the camera to take a photo) would be a confusing, out-of-context
/// permission prompt. Only primes when a previous session already granted access.
enum AudioSessionPrimer {
    static func prime() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let microphone = AVCaptureDevice.default(for: .audio) else { return }
        Diagnostics.time("boot.audioSessionPrime") {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.allowBluetoothHFP, .defaultToSpeaker])
                try AVAudioSession.sharedInstance().setActive(true)
                let input = try AVCaptureDeviceInput(device: microphone)
                let session = AVCaptureSession()
                session.beginConfiguration()
                if session.canAddInput(input) { session.addInput(input) }
                session.commitConfiguration()
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch { Diagnostics.report(error, operation: "Prime audio session") }
        }
    }
}
