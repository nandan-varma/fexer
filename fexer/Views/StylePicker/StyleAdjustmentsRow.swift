import SwiftUI

struct StyleAdjustmentsRow: View {
    @Binding var adjustments: StyleAdjustments
    let isBW: Bool

    var body: some View {
        HStack(spacing: 0) {
            AdjustmentDial(label: "EXP",
                           value: $adjustments.exposure,
                           range: -1.5...1.5,
                           formatValue: { String(format: "%+.1f", $0) })

            AdjustmentDial(label: "CON",
                           value: $adjustments.contrast,
                           range: -0.5...0.5,
                           formatValue: { String(format: "%+.2f", $0) })

            AdjustmentDial(label: "SAT",
                           value: $adjustments.saturation,
                           range: -1.0...1.0,
                           formatValue: { String(format: "%+.2f", $0) },
                           disabled: isBW)

            AdjustmentDial(label: "WARM",
                           value: $adjustments.warmth,
                           range: -1.0...1.0,
                           formatValue: { String(format: "%+.2f", $0) })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct AdjustmentDial: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let formatValue: (Float) -> String
    var disabled: Bool = false

    @State private var isDragging = false
    @State private var dragStart: Float = 0

    private var normalizedPosition: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(disabled ? .white.opacity(0.2) : .white.opacity(0.45))
                .tracking(1)

            GeometryReader { geo in
                let w = geo.size.width
                let center = w / 2
                let pos = normalizedPosition * w

                ZStack(alignment: .leading) {
                    // Base track
                    Capsule()
                        .fill(.white.opacity(disabled ? 0.04 : 0.10))
                        .frame(height: 3)

                    // Yellow fill from center to current position
                    if !disabled && value != 0 {
                        let fillStart = min(center, pos)
                        let fillWidth = abs(pos - center)
                        Capsule()
                            .fill(Color.yellow.opacity(isDragging ? 1.0 : 0.8))
                            .frame(width: fillWidth, height: 3)
                            .offset(x: fillStart)
                    }

                    // Thumb
                    if !disabled {
                        Circle()
                            .fill(isDragging ? Color.yellow : .white)
                            .frame(width: isDragging ? 9 : 6, height: isDragging ? 9 : 6)
                            .offset(x: pos - (isDragging ? 4.5 : 3))
                            .animation(.easeInOut(duration: 0.12), value: isDragging)
                    }
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)

            Text(disabled ? "—" : formattedValue)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(disabled ? .white.opacity(0.15) : (value == 0 ? .white.opacity(0.4) : .yellow))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(disabled ? nil : dragGesture)
        .onTapGesture(count: 2) {
            guard !disabled else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { value = 0 }
            HapticManager.light()
        }
        .animation(.easeInOut(duration: 0.15), value: disabled)
    }

    private var formattedValue: String { formatValue(value) }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if !isDragging {
                    isDragging = true
                    dragStart = value
                    HapticManager.light()
                }
                let span = range.upperBound - range.lowerBound
                let sensitivity = span / 180
                let raw = dragStart + Float(g.translation.width) * sensitivity
                value = Swift.min(Swift.max(raw, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
            }
    }
}
