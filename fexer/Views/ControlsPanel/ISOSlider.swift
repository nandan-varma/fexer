import SwiftUI

struct ISOSlider: View {
    @Binding var iso: Float
    @Binding var isAuto: Bool
    var onChanged: (() -> Void)?

    @State private var doubleISO: Double = 200

    private let isoStops: [Double] = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400]

    var body: some View {
        VStack(spacing: 8) {
            autoToggle

            VerticalDialSlider(
                label: "ISO",
                unit: "",
                value: $doubleISO,
                range: 25...6400,
                steps: isoStops,
                isLogarithmic: true,
                formatValue: { "ISO \(Int($0))" }
            ) {
                iso = Float(doubleISO)
                onChanged?()
            }
            .disabled(isAuto)
            .opacity(isAuto ? 0.45 : 1)
        }
        .onChange(of: iso) { _, new in doubleISO = Double(new) }
        .onAppear { doubleISO = Double(iso) }
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
