import SwiftUI

/// Reusable vertical drag-based dial slider with logarithmic/linear scale.
struct VerticalDialSlider: View {
    let label: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let steps: [Double]?
    let isLogarithmic: Bool
    let formatValue: (Double) -> String
    var onChanged: (() -> Void)?

    @State private var dragStart: Double = 0
    @State private var isDragging = false
    @State private var capsuleOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(1)

            ZStack(alignment: .center) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.12))
                    .frame(width: 3, height: 160)

                // Fill indicator
                let fillHeight = normalizedValue * 160
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: 3, height: fillHeight)
                    .offset(y: (160 - fillHeight) / 2)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(y: (normalizedValue - 0.5) * -160)

                // Value capsule (appears during drag)
                if isDragging {
                    Text(formatValue(value))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.yellow, in: Capsule())
                        .offset(x: 36, y: (normalizedValue - 0.5) * -160)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: 44, height: 170)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            dragStart = value
                        }
                        let sensitivity: Double = isLogarithmic ? 0.008 : (range.upperBound - range.lowerBound) / 160
                        let newValue: Double
                        if isLogarithmic {
                            let logRange = log2(range.upperBound) - log2(range.lowerBound)
                            let logStart = log2(dragStart)
                            newValue = pow(2, (logStart - g.translation.height * sensitivity * logRange).fxClamped(to: log2(range.lowerBound)...log2(range.upperBound)))
                        } else {
                            newValue = (dragStart - g.translation.height * sensitivity).fxClamped(to: range.lowerBound...range.upperBound)
                        }

                        if let steps {
                            let snapped = steps.min(by: { abs($0 - newValue) < abs($1 - newValue) }) ?? newValue
                            if snapped != value { HapticManager.selectionChanged() }
                            value = snapped
                        } else {
                            value = newValue
                        }
                        onChanged?()
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
                    }
            )

            Text(formatValue(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .opacity(isDragging ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.1), value: isDragging)
    }

    private var normalizedValue: Double {
        if isLogarithmic {
            let logRange = log2(range.upperBound) - log2(range.lowerBound)
            return (log2(value.fxClamped(to: range.lowerBound...range.upperBound)) - log2(range.lowerBound)) / logRange
        } else {
            return (value.fxClamped(to: range.lowerBound...range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        }
    }
}
