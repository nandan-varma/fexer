import SwiftUI

struct FocusSlider: View {
    @Binding var lensPosition: Float
    @Binding var isAuto: Bool
    var onChanged: (() -> Void)?

    @State private var doublePosition: Double = 0.5

    var body: some View {
        VStack(spacing: 8) {
            AutoToggleButton(isAuto: $isAuto)

            VerticalDialSlider(
                label: "FOCUS",
                unit: "",
                value: $doublePosition,
                range: 0...1,
                steps: nil,
                isLogarithmic: false,
                formatValue: { v in
                    // Approximate distance in meters (rough heuristic)
                    if v < 0.1 { return "∞" }
                    let meters = 0.1 / v
                    return meters > 10 ? "\(Int(meters))m" : String(format: "%.1fm", meters)
                }
            ) {
                lensPosition = Float(doublePosition)
                onChanged?()
            }
            .disabled(isAuto)
            .opacity(isAuto ? 0.45 : 1)
        }
        .onAppear { doublePosition = Double(lensPosition) }
        .onChange(of: lensPosition) { _, new in doublePosition = Double(new) }
    }

}
