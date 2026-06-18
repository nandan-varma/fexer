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
        let time = stops[idx]
        let seconds = CMTimeGetSeconds(time)
        if seconds >= 1 {
            return seconds.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(seconds))\"" : String(format: "%.1f\"", seconds)
        } else {
            return "1/\(Int(round(1/seconds)))"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            autoToggle

            VerticalDialSlider(
                label: "SHUTTER",
                unit: "",
                value: $sliderIndex,
                range: 0...Double(stops.count - 1),
                steps: sliderSteps,
                isLogarithmic: false,
                formatValue: { [stops] idx in
                    let i = Int(idx).fxClamped(to: 0...(stops.count - 1))
                    let t = stops[i]
                    let s = CMTimeGetSeconds(t)
                    return s >= 1 ? (s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s))\"" : String(format: "%.1f\"", s)) : "1/\(Int(round(1/s)))"
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

    private var autoToggle: some View {
        Button {
            isAuto.toggle()
            HapticManager.selectionChanged()
        } label: {
            Text(isAuto ? "A" : "M")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isAuto ? .black : .white)
                .frame(width: 22, height: 22)
                .background(isAuto ? Color.yellow : Color.white.opacity(0.2), in: Circle())
        }
    }
}
