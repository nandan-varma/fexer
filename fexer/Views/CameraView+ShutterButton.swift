import SwiftUI

extension CameraView {

    // MARK: - Shutter row

    var shutterRow: some View {
        HStack(alignment: .center) {
            if showGallery {
                Button {
                    capturedPhoto = nil
                    withAnimation(.easeInOut(duration: 0.3)) { showReview = true }
                } label: {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .overlay {
                            if let thumb = lastCapturedThumb {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .transition(.opacity)
                            } else {
                                Image(systemName: "photo.stack")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))
                                    .animation(.spring(response: 0.35, dampingFraction: 0.75),
                                               value: DeviceOrientationTracker.shared.rotationAngle)
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: lastCapturedThumb != nil)
                }
            } else {
                Spacer().frame(width: 52, height: 52)
            }

            Spacer()
            shutterButton
            Spacer()
            Spacer().frame(width: 52, height: 52)
        }
    }

    // MARK: - Shutter button

    var shutterButton: some View {
        let ev = cameraManager.captureSettings.exposureCompensation
        let fraction = CGFloat((ev + 3) / 6)
        let aelLocked = cameraViewModel.isAELocked
        let activeMode = cameraViewModel.activeMode
        let isTimelapseActive = cameraViewModel.isTimelapseActive
        let isBurstActive = cameraViewModel.isBurstActive

        // Timelapse: red fill when active, white when idle
        let innerFill: Color = (activeMode == .timelapse && isTimelapseActive) ? .red : .white

        return ZStack {
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction < 0.5 ? Color.blue : Color.orange, lineWidth: 3)
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.1), value: ev)

            Circle()
                .stroke(aelLocked ? Color.yellow : .white, lineWidth: 3)
                .frame(width: 76, height: 76)
                .animation(.easeInOut(duration: 0.15), value: aelLocked)

            // Inner capture button
            // Burst: long-press starts burst, release stops it
            // Timelapse: tap toggles start/stop
            // Other modes: tap to shoot, long-press to toggle AEL
            if activeMode == .burst {
                // Burst shutter — long-press fires continuously
                Circle()
                    .fill(isBurstActive ? Color.orange : .white)
                    .frame(width: 62, height: 62)
                    .animation(.easeInOut(duration: 0.1), value: isBurstActive)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !cameraViewModel.isBurstActive {
                                    cameraViewModel.startBurst(maxShots: burstCount) {
                                        let delegate = makeCaptureDelegate()
                                        activeDelegates[delegate.id] = delegate
                                        return delegate
                                    }
                                }
                            }
                            .onEnded { _ in cameraViewModel.stopBurst() }
                    )
            } else if activeMode == .timelapse {
                // Timelapse shutter — tap toggles
                Button {
                    if isTimelapseActive {
                        cameraViewModel.stopTimelapse()
                    } else {
                        cameraViewModel.startTimelapse {
                            let delegate = makeCaptureDelegate()
                            activeDelegates[delegate.id] = delegate
                            return delegate
                        }
                    }
                } label: {
                    Circle()
                        .fill(innerFill)
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(ShutterButtonStyle())
            } else if activeMode == .video {
                // Video shutter — tap to start/stop recording
                let recording = cameraManager.isRecording
                Button { captureAction() } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 62, height: 62)
                        if recording {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                                .frame(width: 24, height: 24)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: recording)
                }
                .buttonStyle(ShutterButtonStyle())
            } else {
                // Normal shutter — tap to shoot, long-press to toggle AEL
                Button { captureAction() } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(ShutterButtonStyle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in cameraViewModel.toggleAELock() }
                )
            }

            // Night mode multi-frame processing indicator
            if activeMode == .night && cameraManager.isCapturing {
                Circle()
                    .trim(from: 0, to: 0.6)
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 82, height: 82)
                    .rotationEffect(.degrees(nightProcessingAngle))
                    .transition(.opacity)
                    .onAppear {
                        nightProcessingAngle = 0
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            nightProcessingAngle = 360
                        }
                    }
                    .onDisappear { nightProcessingAngle = 0 }
            }

            // AEL badge
            if aelLocked {
                Text("AEL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.yellow, in: Capsule())
                    .offset(y: -48)
                    .transition(.opacity.combined(with: .scale))
            }

            // Burst count badge
            if activeMode == .burst && isBurstActive {
                Text("\(cameraViewModel.burstCount)/\(burstCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .offset(y: 48)
                    .transition(.opacity.combined(with: .scale))
            }

            // Bracket badge
            if isBracketingEnabled && activeMode != .burst {
                let stepLabel = bracketEVStep == 1.0 ? "1" : String(format: "%.1g", bracketEVStep)
                Text("±\(stepLabel)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .offset(y: 48)
            }
        }
    }
}
