import AVFoundation
import SwiftUI

extension CameraView {

    // MARK: - Lens switcher row

    @ViewBuilder
    var lensSwitcherRow: some View {
        let lenses = cameraManager.backLenses
        // Only show on back camera with more than one physical lens
        if lenses.count > 1, cameraManager.currentDevice?.position != .front {
            let opticalFactor = cameraManager.activeLensOpticalFactor
            let digitalZoom = cameraManager.currentZoomFactor
            let liveOptical = opticalFactor * digitalZoom
            let activeLens = lenses.first(where: { $0.device == cameraManager.currentDevice })
            let isAtNative = abs(digitalZoom - 1.0) < 0.05  // at native focal length (no digital zoom)

            VStack(spacing: 10) {
                if isZoomDialActive, let active = activeLens,
                   let device = cameraManager.currentDevice {
                    let minOptical = active.opticalFactor * device.minAvailableVideoZoomFactor
                    let maxOptical = min(active.opticalFactor * device.maxAvailableVideoZoomFactor,
                                        active.opticalFactor * 15)
                    ZoomDial(
                        factors: [minOptical, active.opticalFactor, maxOptical],
                        currentZoom: liveOptical,
                        onZoom: { target in
                            cameraManager.setZoom(target / active.opticalFactor)
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                isZoomDialActive = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }

                HStack(spacing: 10) {
                    ForEach(lenses) { lens in
                        let isActive = lens.device == cameraManager.currentDevice
                        let labelText: String = {
                            if isActive && !isAtNative {
                                return CameraManager.opticalLabel(liveOptical)
                            }
                            return lens.label
                        }()
                        lensButton(lens: lens, isActive: isActive, labelText: labelText)
                    }
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isZoomDialActive)
        }
    }

    @ViewBuilder
    func lensButton(lens: LensOption, isActive: Bool, labelText: String) -> some View {
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
                cameraManager.switchToCamera(lens)
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
}
