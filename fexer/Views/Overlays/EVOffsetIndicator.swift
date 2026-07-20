import SwiftUI

/// Horizontal light-meter needle showing `exposureTargetOffset` from –3 to +3 EV.
/// Displayed in the viewfinder whenever auto-exposure is active.
struct EVOffsetIndicator: View {
    let offset: Float          // live value from device.exposureTargetOffset
    let isAELocked: Bool

    private let range: Float = 3.0

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .center) {
                // Track
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(width: 120, height: 3)

                // Clipping zones (red at extremes)
                HStack(spacing: 0) {
                    Rectangle().fill(Color.blue.opacity(0.55)).frame(width: 20, height: 3)
                    Spacer()
                    Rectangle().fill(Color.red.opacity(0.55)).frame(width: 20, height: 3)
                }
                .frame(width: 120)
                .clipShape(Capsule())

                // Center mark
                Rectangle()
                    .fill(.white.opacity(0.6))
                    .frame(width: 1, height: 9)

                // Needle
                let fraction = CGFloat((offset / range + 1) / 2)
                let x = (fraction - 0.5) * 120
                Circle()
                    .fill(isAELocked ? Color.yellow : Color.white)
                    .frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: x)
                    .animation(.easeOut(duration: 0.1), value: offset)
            }

            // Numeric readout
            let sign = offset >= 0 ? "+" : ""
            Text("\(sign)\(String(format: "%.1f", offset)) EV")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(isAELocked ? .yellow : .white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    ZStack {
        Color.black
        VStack(spacing: 16) {
            EVOffsetIndicator(offset: 0.0, isAELocked: false)
            EVOffsetIndicator(offset: 1.3, isAELocked: false)
            EVOffsetIndicator(offset: -2.1, isAELocked: true)
        }
    }
}
