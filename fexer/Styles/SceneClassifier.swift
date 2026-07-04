import Vision
import AVFoundation
import Observation
import OSLog
import os

/// Classifies scenes from camera frames to suggest photographic styles.
/// Runs inference at ~2fps; debounces suggestions to avoid flickering.
@Observable
final class SceneClassifier {
    private static let log = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
    var suggestedStyle: PhotoStyle?

    var isEnabled = true {
        didSet { enabledLock.withLock { $0 = isEnabled } }
    }

    private let enabledLock = OSAllocatedUnfairLock(initialState: true)
    private let stateQueue = DispatchQueue(label: "com.fexer.sceneClassifier", qos: .utility)
    private var frameCounter = 0
    private var pendingMatch: PhotoStyle?
    private var consecutiveCount = 0
    private let debounceThreshold = 3

    private let sceneMapping: [String: PhotoStyle] = {
        let catalog = PhotoStyle.catalog
        func find(_ name: String) -> PhotoStyle? { catalog.first { $0.name == name } }
        return [
            "landscape": find("Landscape") ?? .none,
            "mountain": find("Landscape") ?? .none,
            "ocean": find("Landscape") ?? .none,
            "forest": find("Landscape") ?? .none,
            "sky": find("Landscape") ?? .none,
            "night": find("Astro") ?? .none,
            "nighttime": find("Astro") ?? .none,
            "bedroom": find("Dreamy") ?? .none,
            "interior": find("Dreamy") ?? .none,
            "portrait": find("Portrait Warm") ?? .none,
            "person": find("Portrait Warm") ?? .none,
            "street": find("Street") ?? .none,
            "urban": find("Street") ?? .none,
            "city": find("Street") ?? .none,
            "food": find("Golden Hour") ?? .none,
            "architecture": find("Architecture") ?? .none,
            "building": find("Architecture") ?? .none
        ]
    }()

    nonisolated func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard enabledLock.withLock({ $0 }) else { return }
        frameCounter = (frameCounter + 1) % 3600
        guard frameCounter % 30 == 0 else { return } // ~2fps at 60fps

        let request = VNClassifyImageRequest { [weak self] request, error in
            if let error {
                Self.log.error("Scene classification failed: \(error.localizedDescription)")
                return
            }
            guard let results = request.results as? [VNClassificationObservation],
                  let top = results.first(where: { $0.confidence > 0.3 })
            else { return }

            self?.updateSuggestion(label: top.identifier.lowercased())
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Self.log.error("VNImageRequestHandler.perform failed: \(error.localizedDescription)")
        }
    }

    private func updateSuggestion(label: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let matched = self.sceneMapping.first { label.contains($0.key) }?.value
            let matchedID = matched?.id

            if matchedID == self.pendingMatch?.id {
                self.consecutiveCount += 1
            } else {
                self.pendingMatch = matched
                self.consecutiveCount = 1
            }

            if self.consecutiveCount >= self.debounceThreshold {
                let style = matched
                Task { @MainActor in
                    self.suggestedStyle = style
                }
                self.consecutiveCount = 0
            }
        }
    }
}
