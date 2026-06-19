import SwiftUI

private let kColumnWidth: CGFloat = 68
private let kTrackHeight: CGFloat = 160
private let kWheelWidth: CGFloat = 34

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
    @State private var lastHapticTick: Double = .nan

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .tracking(1.5)
                .frame(width: kColumnWidth)

            Text(isDragging ? " " : formatValue(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: kColumnWidth, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            ZStack {
                drumWheel
                centerIndicator

                if isDragging {
                    Text(formatValue(value))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.yellow, in: Capsule())
                        .fixedSize()
                        .offset(x: kColumnWidth * 0.6)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                        .zIndex(1)
                }
            }
            .frame(width: kColumnWidth, height: kTrackHeight + 20)
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
        .frame(width: kColumnWidth)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
    }

    // MARK: - Drum wheel

    private var drumWheel: some View {
        let v = value
        let r = range
        let isLog = isLogarithmic
        let stepsArr = steps

        return Canvas { ctx, size in
            let cy = size.height / 2
            let cx = size.width / 2

            if let steps = stepsArr {
                // Stepped: one tick per stop, scrolls 1:1 with drag
                let lo = isLog ? log2(r.lowerBound) : r.lowerBound
                let hi = isLog ? log2(r.upperBound) : r.upperBound
                let pxPerUnit = size.height / (hi - lo)
                let vLog = isLog ? log2(max(v, r.lowerBound)) : v

                for step in steps {
                    let stepLog = isLog ? log2(step) : step
                    let py = cy + CGFloat(vLog - stepLog) * pxPerUnit
                    guard py > -8 && py < size.height + 8 else { continue }

                    let dist = Double(abs(py - cy))
                    let t = max(0, 1 - dist / Double(size.height * 0.44))
                    let isCenter = dist < 3
                    let w = CGFloat(isCenter ? 26 : t * 18 + 8)
                    let alpha = isCenter ? 1.0 : t * 0.5 + 0.1

                    let rect = CGRect(x: cx - w / 2, y: py - 1.5, width: w, height: 3)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(.white.opacity(alpha)))
                }
            } else {
                // Continuous: major + minor ticks, density calibrated to drag sensitivity
                let span = r.upperBound - r.lowerBound
                let pxPerUnit = size.height / span
                let majorInt = niceInterval(span / 10)
                let minorInt = majorInt / 5

                // Minor ticks
                var tick = (r.lowerBound / minorInt).rounded(.up) * minorInt
                while tick <= r.upperBound * 1.001 {
                    let py = cy + CGFloat(v - tick) * pxPerUnit
                    if py >= 0 && py <= size.height {
                        let t = max(0, 1 - Double(abs(py - cy)) / Double(size.height * 0.5))
                        let rect = CGRect(x: cx - 6, y: py - 1, width: 12, height: 2)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(.white.opacity(t * 0.2)))
                    }
                    tick += minorInt
                }

                // Major ticks
                tick = (r.lowerBound / majorInt).rounded(.up) * majorInt
                while tick <= r.upperBound * 1.001 {
                    let py = cy + CGFloat(v - tick) * pxPerUnit
                    if py >= -4 && py <= size.height + 4 {
                        let dist = Double(abs(py - cy))
                        let isCenter = dist < 3
                        let t = max(0, 1 - dist / Double(size.height * 0.44))
                        let w = CGFloat(isCenter ? 26 : t * 16 + 8)
                        let alpha = t * (isCenter ? 0.9 : 0.62) + 0.08
                        let rect = CGRect(x: cx - w / 2, y: py - 1.5, width: w, height: 3)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(.white.opacity(alpha)))
                    }
                    tick += majorInt
                }
            }
        }
        .frame(width: kWheelWidth, height: kTrackHeight)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Center indicator: two arrow chevrons flanking the wheel

    private var centerIndicator: some View {
        HStack(spacing: kWheelWidth - 4) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 8))
                .foregroundStyle(.yellow.opacity(0.9))
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 8))
                .foregroundStyle(.yellow.opacity(0.9))
        }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !isDragging {
                    isDragging = true
                    dragStart = value
                    lastHapticTick = value
                }

                var newValue: Double
                if isLogarithmic {
                    let lo = log2(range.lowerBound), hi = log2(range.upperBound)
                    let logRange = hi - lo
                    let logDelta = g.translation.height / kTrackHeight * logRange
                    newValue = pow(2, (log2(dragStart) + logDelta).fxClamped(to: lo...hi))
                } else {
                    let sensitivity = (range.upperBound - range.lowerBound) / kTrackHeight
                    newValue = (dragStart + g.translation.height * sensitivity).fxClamped(to: range)
                }

                if let steps {
                    let snapped = steps.min(by: { abs($0 - newValue) < abs($1 - newValue) }) ?? newValue
                    if snapped != value { HapticManager.selectionChanged() }
                    value = snapped
                } else {
                    // Haptic at every major tick crossing
                    let majorInt = niceInterval((range.upperBound - range.lowerBound) / 10)
                    if !lastHapticTick.isNaN {
                        let prev = Int((lastHapticTick / majorInt).rounded(.down))
                        let curr = Int((newValue / majorInt).rounded(.down))
                        if curr != prev { HapticManager.selectionChanged() }
                    }
                    lastHapticTick = newValue
                    value = newValue
                }
                onChanged?()
            }
            .onEnded { _ in
                lastHapticTick = .nan
                withAnimation(.easeOut(duration: 0.18)) { isDragging = false }
            }
    }

    // MARK: - Helpers

    private func niceInterval(_ v: Double) -> Double {
        let magnitude = pow(10.0, floor(log10(max(v, 1e-10))))
        let normalized = v / magnitude
        if normalized < 1.5 { return magnitude }
        if normalized < 3.5 { return 2 * magnitude }
        if normalized < 7.5 { return 5 * magnitude }
        return 10 * magnitude
    }
}


