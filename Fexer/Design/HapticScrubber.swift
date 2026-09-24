import SwiftUI
import UIKit

private struct HapticsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Set once near the app root from `Preferences.haptics`; scrubbers everywhere read it
    /// instead of threading the preference through every intermediate view/model.
    var hapticsEnabled: Bool {
        get { self[HapticsEnabledKey.self] }
        set { self[HapticsEnabledKey.self] = newValue }
    }
}

/// A drag-to-scrub ruler in the style of a pro camera app's manual controls: the value ticks
/// scroll under a fixed center indicator (direct manipulation, like a scroll view), with a
/// selection haptic on every tick crossed and a firmer one at the ends of the range.
///
/// Tick spacing is a real unit of the value being adjusted (`minorStep`), not a cosmetic count —
/// pass e.g. a third of a stop for a log2-domain ISO/shutter binding, or 100K for a Kelvin white
/// balance range, so the ruler's gradations mean what a photographer expects them to mean.
struct HapticScrubber: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: String? = nil
    /// Value-space distance between adjacent ticks. Defaults to a purely cosmetic 1/60th of the
    /// range, for edit-recipe sliders (hue, curves, crop…) that have no real-world unit.
    var minorStep: Double? = nil
    /// How many minor ticks between each taller/brighter major tick.
    var majorEvery: Int = 5
    /// Suppresses the title/value row, showing just the ruler — for embedding in a fixed-height
    /// bar (e.g. the camera top bar) where the pill below already displays the live value.
    var compact: Bool = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.hapticsEnabled) private var hapticsEnabled
    @State private var dragStartValue: Double?
    @State private var lastHapticStep: Int?
    @State private var atLimit = false
    @State private var isDragging = false

    private let tickSpacing: CGFloat = 10

    private var step: Double {
        let span = range.upperBound - range.lowerBound
        return minorStep ?? (span > 0 ? span / 60 : 1)
    }
    private var tickCount: Int {
        let span = range.upperBound - range.lowerBound
        guard step > 0 else { return 1 }
        return max(1, Int((span / step).rounded()))
    }
    private var normalized: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    var body: some View {
        Group {
            if compact {
                rulerArea(indicatorHeight: 22).frame(height: 40)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text(title).font(.subheadline)
                        Spacer()
                        Text(display ?? String(format: "%+.2f", value))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Theme.accent)
                    }
                    rulerArea(indicatorHeight: 28).frame(height: 44)
                }.padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(display ?? String(format: "%+.2f", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = (value + step).bounded(range)
            case .decrement: value = (value - step).bounded(range)
            default: break
            }
        }
    }

    private func rulerArea(indicatorHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                ruler(width: width)
                Capsule().fill(Theme.accent).frame(width: 2, height: indicatorHeight)
            }
            .frame(width: width)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
            .scaleEffect(isDragging ? 1.03 : 1, anchor: .center)
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
    }

    private func ruler(width: CGFloat) -> some View {
        let totalWidth = CGFloat(tickCount) * tickSpacing
        let offset = width / 2 - CGFloat(normalized) * totalWidth
        let majorHeight: CGFloat = compact ? 18 : 24
        let minorHeight: CGFloat = compact ? 9 : 13
        return HStack(spacing: tickSpacing - 1.5) {
            ForEach(0...tickCount, id: \.self) { tick in
                Capsule()
                    .fill(Theme.muted.opacity(tick % majorEvery == 0 ? 0.7 : 0.35))
                    .frame(width: 1.5, height: tick % majorEvery == 0 ? majorHeight : minorHeight)
            }
        }
        .frame(width: totalWidth, alignment: .leading)
        .offset(x: offset)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if dragStartValue == nil {
                    dragStartValue = value
                    lastHapticStep = Int((normalized * Double(tickCount)).rounded())
                    isDragging = true
                    onEditingChanged(true)
                }
                let totalWidth = CGFloat(tickCount) * tickSpacing
                let span = range.upperBound - range.lowerBound
                let startNormalized = (dragStartValue! - range.lowerBound) / span
                let draggedNormalized = startNormalized - Double(drag.translation.width / totalWidth)
                let clamped = draggedNormalized.bounded(0...1)
                let newValue = range.lowerBound + clamped * span
                if newValue != value {
                    value = newValue
                    fireTickHaptic(normalized: clamped)
                }
                let reachedLimit = draggedNormalized <= 0 || draggedNormalized >= 1
                if reachedLimit, !atLimit { fireLimitHaptic() }
                atLimit = reachedLimit
            }
            .onEnded { _ in
                dragStartValue = nil
                lastHapticStep = nil
                atLimit = false
                isDragging = false
                onEditingChanged(false)
            }
    }

    private func fireTickHaptic(normalized: Double) {
        guard hapticsEnabled else { return }
        let step = Int((normalized * Double(tickCount)).rounded())
        guard step != lastHapticStep else { return }
        lastHapticStep = step
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func fireLimitHaptic() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
    }
}
