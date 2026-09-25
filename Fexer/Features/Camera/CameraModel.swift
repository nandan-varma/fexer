import CoreImage
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class CameraModel {
    private(set) var phase: CameraPhase = .idle
    private(set) var activity: CaptureActivity = .idle
    private(set) var capabilities = CameraCapabilities()
    private(set) var reading = CameraReading()
    var controls = CameraControls()
    var recipe = EditRecipe()
    var mode: CaptureMode = .photo
    var issue: AppIssue?
    var review: LibraryItem?
    var announcement = ""
    private(set) var pendingCapture: PhotoPayload?
    let service: any CameraOperating
    let frames: FrameProcessor
    let library: LibraryModel
    var preferences: PreferenceStore
    let location = LocationService()
    let level = LevelService()
    private var eventsTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var pendingRecipe = EditRecipe()
    private var pendingLocation: GeoTag?
    private var active = false

    init(service: any CameraOperating, frames: FrameProcessor, library: LibraryModel, preferences: PreferenceStore) {
        self.service = service; self.frames = frames; self.library = library; self.preferences = preferences
        eventsTask = Task { [weak self, service] in
            for await event in await service.events {
                guard let self else { return }
                switch event {
                case .phase(let phase): self.phase = phase
                case .capabilities(let value): capabilities = value
                case .reading(let value): reading = value
                }
            }
        }
    }

    func start() async {
        active = true
        location.setEnabled(preferences.value.location)
        level.setEnabled(preferences.value.level)
        do { try await service.start(); updatePreview() }
        catch { show(error, operation: "Start camera") }
    }
    func stop() async {
        active = false
        captureTask?.cancel()
        location.setEnabled(false)
        level.setEnabled(false)
        await service.stop()
    }
    func updatePreview() {
        previewTask?.cancel()
        let edit = mode == .video ? EditRecipe() : recipe
        let options = preferences.value
        previewTask = Task {
            do {
                let prepared = try await library.renderer.prepare(edit)
                try Task.checkCancellation()
                await service.setPreview(.init(recipe: prepared, monitor: options.monitor, peaking: options.peaking, zebras: options.zebras, falseColor: options.falseColor))
            } catch is CancellationError {} catch { show(error, operation: "Apply style") }
        }
    }
    /// Pays the session-reconfiguration cost (preset change, mic input, movie output) whenever
    /// the target mode or its settings (4K/fps) change, so tapping record itself does no
    /// reconfiguration. Idempotent — the service no-ops if nothing actually changed.
    func updateCaptureMode() {
        let video4K = preferences.value.video4K
        let videoFPS = preferences.value.videoFPS
        let wantsVideo = mode == .video
        Task {
            if wantsVideo { await service.prewarmVideo(fourK: video4K, fps: videoFPS) }
            else { await service.prewarmPhoto() }
        }
    }
    func updateControls() {
        controlTask?.cancel()
        let value = controls
        controlTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(40))
                try await service.apply(value)
            } catch is CancellationError {} catch { show(error, operation: "Set camera controls") }
        }
    }
    func selectLens(_ lens: CameraLens) async {
        do {
            try await Diagnostics.time("model.selectLens") { try await service.selectLens(lens.id) }
            controls = CameraControls()
            if !capabilities.supportsRAW { preferences.value.format = .heif }
        } catch { show(error, operation: "Switch camera") }
    }
    func focus(_ point: CGPoint, size: CGSize) {
        let source = frames.snapshot().raw?.extent.size ?? CGSize(width: 3, height: 4)
        let sensor = CropGeometry.focusPoint(point, view: size, image: source, mirrored: capabilities.isFront)
        Task { do { try await service.focus(at: sensor) } catch { show(error, operation: "Focus camera") } }
    }
    func shutter() {
        if activity.isRecording { Task { await service.finishMovie() }; activity = .finishing; return }
        if !activity.isIdle { captureTask?.cancel(); return }
        guard phase == .ready, pendingCapture == nil else { return }
        if preferences.value.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        activity = .capturing
        let selectedMode = mode
        let tapTime = ContinuousClock.now
        captureTask = Task {
            defer {
                activity = .idle; captureTask = nil
                // The literal "how long was the shutter unresponsive" metric — what the user feels.
                Diagnostics.mark("shutter.tapToReady", since: tapTime)
            }
            do {
                let delay = preferences.value.timerSeconds
                if delay > 0 {
                    for second in stride(from: delay, through: 1, by: -1) {
                        activity = .countdown(second)
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try Task.checkCancellation()
                if selectedMode == .video {
                    // Recording may not start immediately (a session reconfigure can still be
                    // running as a fallback) — show the same "please wait" spinner as a photo
                    // capture until AVFoundation confirms it's actually rolling, so the displayed
                    // timer's start time is accurate rather than counting time that was spent
                    // waiting on setup.
                    activity = .capturing
                    let url = try await service.recordMovie(fourK: preferences.value.video4K, fps: preferences.value.videoFPS) {
                        Diagnostics.mark("shutter.recordTapToRolling", since: tapTime)
                        Task { @MainActor in self.activity = .recording(Date()) }
                    }
                    activity = .finishing
                    _ = try await library.acceptVideo(url: url, location: location.location, autoExport: preferences.value.saveToPhotos)
                    try? FileManager.default.removeItem(at: url)
                    announcement = "Video saved"
                } else if selectedMode == .lightTrails {
                    try await captureTrails()
                } else {
                    let count = selectedMode == .burst ? preferences.value.burstCount : selectedMode == .interval ? 999 : 1
                    for index in 0..<count {
                        try Task.checkCancellation()
                        guard active else { throw CancellationError() }
                        activity = count == 1 ? .capturing : .sequence(index + 1)
                        try await captureOne()
                        if selectedMode == .interval { try await Task.sleep(for: .seconds(preferences.value.intervalSeconds)) }
                    }
                }
            } catch is CancellationError {} catch { show(error, operation: "Capture") }
        }
    }
    private func captureOne() async throws {
        let settings = preferences.value
        let capturedRecipe = recipe
        let geo = location.location
        let payload = try await Diagnostics.time("model.serviceCapture") {
            try await service.capture(.init(format: settings.format, flash: settings.flash,
                                            livePhoto: settings.livePhoto, proRAW: settings.proRAW))
        }
        // Once the camera returns pixels, finish the durable save even if the user backgrounds the app.
        pendingCapture = payload; pendingRecipe = capturedRecipe; pendingLocation = geo
        try await Diagnostics.time("model.persistPending") { try await persistPending(autoExport: settings.saveToPhotos) }
    }
    func retrySave() async {
        do { try await persistPending(autoExport: preferences.value.saveToPhotos) }
        catch { show(error, operation: "Save capture") }
    }
    private func persistPending(autoExport: Bool) async throws {
        guard let payload = pendingCapture else { return }
        let saved = try await Diagnostics.time("model.libraryAccept (local save, gates pendingCapture/shutter)") {
            try await library.accept(payload, recipe: pendingRecipe, location: pendingLocation, autoExport: autoExport)
        }
        pendingCapture = nil
        if let movie = payload.liveMovieURL { try? FileManager.default.removeItem(at: movie) }
        announcement = "Saved to Fexer"
        if preferences.value.reviewAfterCapture { review = saved }
    }
    private func captureTrails() async throws {
        activity = .capturing
        let duration = preferences.value.trailSeconds.bounded(1...30, fallback: 4)
        let processor = TrailAccumulator()
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(duration) {
            try Task.checkCancellation()
            if let image = frames.snapshot().raw { try await processor.add(image) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let data = try await processor.finish()
        pendingCapture = PhotoPayload(processed: data); pendingRecipe = recipe; pendingLocation = location.location
        try await persistPending(autoExport: preferences.value.saveToPhotos)
    }
    private func show(_ error: any Error, operation: String) {
        Diagnostics.report(error, operation: operation)
        issue = error as? AppIssue ?? AppIssue(operation + " failed", pendingCapture == nil ? "Please try again. Your saved captures are safe." : "The capture is held in memory. Free some storage, then tap Retry save before closing Fexer.")
    }
}

/// Flatten each composite to prevent an ever-growing CI graph. Output is preview resolution.
actor TrailAccumulator {
    private var image: CIImage?
    func add(_ frame: CIImage) throws {
        let result = image.map { frame.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? frame
        guard let pixels = ImagePipeline.context.createCGImage(result, from: result.extent) else { throw AppIssue.exportFailed }
        image = CIImage(cgImage: pixels)
    }
    func finish() throws -> Data {
        guard let image, let data = ImagePipeline.context.jpegRepresentation(of: image, colorSpace: ImagePipeline.colorSpace) else { throw AppIssue.captureFailed }
        return data
    }
}
