import SwiftUI

private let kColumnWidth: CGFloat = 68
private let kTrackHeight: CGFloat = 160

/// Vertical drag-based dial slider. Fixed-width column prevents layout shifts when values change.
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

    var body: some View {
        VStack(spacing: 8) {
            // ── Label ─────────────────────────────────────────────────
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .tracking(1.5)
                .frame(width: kColumnWidth)

            // ── Track + thumb ─────────────────────────────────────────
            ZStack(alignment: .center) {
                // Background track
                Capsule()
                    .fill(.white.opacity(0.1))
                    .frame(width: 4, height: kTrackHeight)

                // Filled portion (bottom → thumb)
                let fillH = normalizedValue * kTrackHeight
                Capsule()
                    .fill(Color.yellow.opacity(0.9))
                    .frame(width: 4, height: max(4, fillH))
                    .offset(y: (kTrackHeight - fillH) / 2)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(y: thumbOffset)

                // Floating value capsule while dragging (absolutely positioned — doesn't affect layout)
                if isDragging {
                    Text(formatValue(value))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.yellow, in: Capsule())
                        .fixedSize()
                        .offset(x: kColumnWidth * 0.6, y: thumbOffset)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                        .zIndex(1)
                }
            }
            .frame(width: kColumnWidth, height: kTrackHeight + 20)
            .contentShape(Rectangle())
            .gesture(dragGesture)

            // ── Value label — fixed-width, monospaced digits to kill layout shift ──
            Text(isDragging ? " " : formatValue(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: kColumnWidth, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: kColumnWidth)   // ← Hard column width; sibling sliders never shift
        .animation(.easeInOut(duration: 0.12), value: isDragging)
    }

    // MARK: - Geometry helpers

    private var normalizedValue: Double {
        if isLogarithmic {
            let lo = log2(range.lowerBound), hi = log2(range.upperBound)
            return (log2(value.fxClamped(to: range)) - lo) / (hi - lo)
        } else {
            return (value.fxClamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
        }
    }

    // Y-offset: 0 at bottom of track (min), -kTrackHeight at top (max)
    private var thumbOffset: CGFloat { (normalizedValue - 0.5) * -kTrackHeight }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !isDragging {
                    isDragging = true
                    dragStart = value
                }

                var newValue: Double
                if isLogarithmic {
                    let lo = log2(range.lowerBound), hi = log2(range.upperBound)
                    let logRange = hi - lo
                    // 160 pt drag = full log range
                    let logDelta = g.translation.height / kTrackHeight * logRange
                    newValue = pow(2, (log2(dragStart) - logDelta).fxClamped(to: lo...hi))
                } else {
                    let sensitivity = (range.upperBound - range.lowerBound) / kTrackHeight
                    newValue = (dragStart - g.translation.height * sensitivity).fxClamped(to: range)
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
                withAnimation(.easeOut(duration: 0.18)) { isDragging = false }
            }
    }
}

private extension Double {
    func fxClamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
