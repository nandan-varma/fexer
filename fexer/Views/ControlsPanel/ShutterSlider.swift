import SwiftUI
import AVFoundation

struct ShutterSlider: View {
    @Binding var shutterSpeed: CMTime
    @Binding var isAuto: Bool
    var onChanged: (() -> Void)?

    @State private var sliderIndex: Double = 5

    private let stops: [CMTime] = CaptureSettings.shutterStops

    private var sliderSteps: [Double] { (0..<stops.count).map(Double.init) }

    private var displayString: String {
        let idx = Int(sliderIndex).fxClamped(to: 0...(stops.count - 1))
        return CaptureSettings.formatShutterSpeed(CMTimeGetSeconds(stops[idx]))
    }

    var body: some View {
        VStack(spacing: 8) {
            AutoToggleButton(isAuto: $isAuto)

            VerticalDialSlider(
                label: "SHUTTER",
                unit: "",
                value: $sliderIndex,
                range: 0...Double(stops.count - 1),
                steps: sliderSteps,
                isLogarithmic: false,
                formatValue: { [stops] idx in
                    let i = Int(idx).fxClamped(to: 0...(stops.count - 1))
                    return CaptureSettings.formatShutterSpeed(CMTimeGetSeconds(stops[i]))
                }
            ) {
                let idx = Int(sliderIndex).fxClamped(to: 0...(stops.count - 1))
                shutterSpeed = stops[idx]
                onChanged?()
            }
            .disabled(isAuto)
            .opacity(isAuto ? 0.45 : 1)
        }
        .onAppear { syncFromBinding() }
        .onChange(of: shutterSpeed) { syncFromBinding() }
    }

    private func syncFromBinding() {
        let targetSeconds = CMTimeGetSeconds(shutterSpeed)
        let bestIdx = stops.enumerated().min(by: {
            abs(CMTimeGetSeconds($0.element) - targetSeconds) < abs(CMTimeGetSeconds($1.element) - targetSeconds)
        })?.offset ?? 0
        sliderIndex = Double(bestIdx)
    }

}
