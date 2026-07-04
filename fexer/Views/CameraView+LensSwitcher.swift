import SwiftUI

extension CameraView {

    // MARK: - Zoom strip

    @ViewBuilder
    var lensSwitcherRow: some View {
        let factors = cameraManager.availableZoomFactors
        if factors.count > 1 {
            let live = cameraManager.currentZoomFactor
            let activeFactor = factors.min(by: { abs($0 - live) < abs($1 - live) }) ?? factors[0]
            let isAtStop = abs(live - activeFactor) < 0.05

            VStack(spacing: 10) {
                if isZoomDialActive {
                    ZoomDial(
                        factors: factors,
                        currentZoom: live,
                        onZoom: { cameraManager.setZoom($0) },
                        onDismiss: {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                isZoomDialActive = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }

                HStack(spacing: 10) {
                    ForEach(factors, id: \.self) { factor in
                        let isActive = factor == activeFactor
                        let labelText = isActive && !isAtStop ? liveZoomLabel(live) : zoomStopLabel(factor)
                        lensButton(factor: factor, isActive: isActive, labelText: labelText)
                    }
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isZoomDialActive)
        }
    }

    @ViewBuilder
    func lensButton(factor: CGFloat, isActive: Bool, labelText: String) -> some View {
        if isActive {
            Button {
                if isZoomDialActive {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { isZoomDialActive = false }
                }
            } label: {
                lensButtonLabel(text: labelText, isActive: true)
            }
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in
                        guard !isZoomDialActive else { return }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            isZoomDialActive = true
                        }
                        HapticManager.selectionChanged()
                    }
            )
        } else {
            Button {
                cameraManager.setZoom(factor)
                HapticManager.selectionChanged()
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { isZoomDialActive = false }
            } label: {
                lensButtonLabel(text: labelText, isActive: false)
            }
        }
    }

    @ViewBuilder
    func lensButtonLabel(text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: isActive ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(isActive ? .black : .white)
            .frame(minWidth: 44, minHeight: 40)
            .padding(.horizontal, 4)
            .background(
                isActive
                    ? AnyShapeStyle(Color.yellow)
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Circle()
            )
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isActive)
    }

    // Converts a raw AVFoundation videoZoomFactor to an optical label using the hardware's
    // main-camera reference point (e.g., raw 1.0 on a triple camera with mainFactor=2 → ".5×",
    // raw 2.0 → "1×", raw 6.0 → "3×"). Matches stock iOS camera label format.
    func opticalLabel(_ rawFactor: CGFloat) -> String {
        let optical = rawFactor / cameraManager.mainCameraZoomFactor
        if optical < 1.0 {
            let s = String(format: "%g", optical)  // e.g. "0.5", "0.75"
            let trimmed = s.hasPrefix("0") ? String(s.dropFirst()) : s  // ".5", ".75"
            return trimmed + "\u{00D7}"
        }
        let r = (optical * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))\u{00D7}" }
        return String(format: "%.1f\u{00D7}", r)
    }

    func zoomStopLabel(_ factor: CGFloat) -> String { opticalLabel(factor) }
    func liveZoomLabel(_ factor: CGFloat) -> String { opticalLabel(factor) }
}
