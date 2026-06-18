import SwiftUI

struct WhiteBalanceSlider: View {
    @Binding var kelvin: Float
    @Binding var isAuto: Bool
    var onChanged: (() -> Void)?

    @State private var doubleKelvin: Double = 5500

    var body: some View {
        VStack(spacing: 8) {
            AutoToggleButton(isAuto: $isAuto)

            ZStack {
                // Colored gradient track behind the slider
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.55, blue: 0.2),
                        Color(red: 1.0, green: 0.9,  blue: 0.7),
                        Color(red: 0.8, green: 0.9,  blue: 1.0),
                        Color(red: 0.5, green: 0.7,  blue: 1.0)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(width: 6, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                VerticalDialSlider(
                    label: "WB",
                    unit: "K",
                    value: $doubleKelvin,
                    range: 2000...8000,
                    steps: nil,
                    isLogarithmic: false,
                    formatValue: { "\(Int($0))K" }
                ) {
                    kelvin = Float(doubleKelvin)
                    onChanged?()
                }
            }
            .disabled(isAuto)
            .opacity(isAuto ? 0.45 : 1)
        }
        .onAppear { doubleKelvin = Double(kelvin) }
        .onChange(of: kelvin) { _, new in doubleKelvin = Double(new) }
    }

}
