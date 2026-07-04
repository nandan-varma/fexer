import SwiftUI

extension CameraView {

    // MARK: - Shooting mode picker + advisory

    /// Horizontally scrollable shooting mode selector with advisory label below.
    var shootingModePicker: some View {
        VStack(spacing: 4) {
            // Advisory / status line
            modeAdvisoryLine

            // Scrollable mode tabs with frosted glass background
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(ShootingMode.allCases.enumerated()), id: \.offset) { idx, mode in
                            let isActive = cameraViewModel.activeModeIndex == idx
                            Button {
                                cameraViewModel.selectMode(
                                    index: idx,
                                    cropRatioRaw: $cropRatioRaw,
                                    selfTimerDelay: $selfTimerDelay
                                )
                            } label: {
                                VStack(spacing: 3) {
                                    HStack(spacing: 4) {
                                        if mode == .night {
                                            Image(systemName: "moon.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.yellow)
                                                .opacity(isActive ? 1 : 0)
                                        }
                                        Text(mode.rawValue.uppercased())
                                            .font(.system(size: 10, weight: isActive ? .bold : .semibold))
                                            .foregroundStyle(isActive ? .yellow : .white.opacity(0.45))
                                            .tracking(1.2)
                                    }
                                    Capsule()
                                        .fill(isActive ? Color.yellow : Color.clear)
                                        .frame(height: 2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: geo.size.width, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: 38)
            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    var modeIconBadge: some View {
        switch cameraViewModel.activeMode {
        case .night:
            Image(systemName: "moon.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)
        case .portrait:
            Image(systemName: "person.crop.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple.opacity(0.9))
        case .timelapse:
            if cameraViewModel.isTimelapseActive {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    var modeAdvisoryLine: some View {
        switch cameraViewModel.activeMode {
        case .longExposure:
            if cameraManager.processor.isLongExposureCapturing {
                Text("CAPTURING…")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                    .tracking(1.5)
            } else {
                VStack(spacing: 6) {
                    HStack {
                        Text("BLEND")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.7))
                            .tracking(1.5)
                        Spacer()
                        Text("\(Int(longExposureDuration))S — USE A TRIPOD")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.85))
                    }
                    Slider(value: $longExposureDuration, in: 1...30, step: 1)
                        .tint(.orange)
                }
                .padding(.horizontal, 16)
            }
        case .timelapse:
            HStack(spacing: 8) {
                if cameraViewModel.isTimelapseActive {
                    Text("\(cameraViewModel.timelapseCount) FRAMES")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                } else {
                    Text("\(timelapseIntervalLabel) INTERVAL")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .tracking(1)
        case .portrait:
            if cameraManager.isDepthDataSupported {
                Text("PORTRAIT")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.purple.opacity(0.7))
                    .tracking(1.5)
            } else {
                Text("DEPTH UNAVAILABLE — FLIP TO BACK CAMERA")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .tracking(1.5)
            }
        case .burst:
            if cameraViewModel.isBurstActive {
                Text("\(cameraViewModel.burstCount) / \(burstCount) FRAMES")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                    .tracking(1.5)
            } else {
                HStack {
                    Text("BURST")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.7))
                        .tracking(1.5)
                    Spacer()
                    Text("\(burstCount) FRAMES")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.85))
                }
                .padding(.horizontal, 16)
                Slider(value: Binding(
                    get: { Double(burstCount) },
                    set: { burstCount = Int($0) }
                ), in: 2...40, step: 1)
                .tint(.orange)
                .padding(.horizontal, 16)
            }
        case .selfTimer:
            VStack(spacing: 6) {
                HStack {
                    Text("DELAY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .tracking(1.5)
                    Spacer()
                    let delayLabel = selfTimerDelay == 0 ? "OFF" : "\(selfTimerDelay)S"
                    Text(delayLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Slider(value: Binding(
                    get: { Double(selfTimerDelay) },
                    set: { selfTimerDelay = Int($0) }
                ), in: 0...30, step: 1)
                .tint(.white.opacity(0.7))
                HStack {
                    Text("REPEAT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .tracking(1.5)
                    Spacer()
                    let repeatLabel = selfTimerRepeat == 0 ? "∞" : "\(selfTimerRepeat)×"
                    Text(repeatLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Slider(value: Binding(
                    get: { Double(selfTimerRepeat) },
                    set: { selfTimerRepeat = Int($0) }
                ), in: 0...10, step: 1)
                .tint(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
        case .night:
            Text(cameraManager.isCapturing ? "HOLD STILL — PROCESSING" : "NIGHT — KEEP CAMERA STEADY")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.yellow.opacity(cameraManager.isCapturing ? 0.9 : 0.55))
                .tracking(1.5)
                .animation(.easeInOut(duration: 0.2), value: cameraManager.isCapturing)
        case .photo:
            if cameraManager.isHDRFormatSupported {
                HStack(spacing: 8) {
                    Button {
                        isHDREnabled.toggle()
                        cameraManager.setHDREnabled(isHDREnabled)
                        HapticManager.light()
                    } label: {
                        Text("HDR")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isHDREnabled ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isHDREnabled ? Color.yellow : .white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
        case .video:
            videoControlsRow
        default:
            EmptyView()
        }
    }

    var timelapseIntervalLabel: String {
        let secs = cameraViewModel.timelapseInterval
        if secs < 60 {
            return "\(Int(secs))s"
        } else {
            return "\(Int(secs / 60))m"
        }
    }

    var videoControlsRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Frame rate picker — only show rates the device actually supports
                let supportedFPS = cameraManager.supportedFrameRates(for: videoResolution)
                ForEach(supportedFPS, id: \.self) { fps in
                    let isActive = videoFrameRate == fps
                    Button {
                        videoFrameRate = fps
                        cameraManager.configureVideoFrameRate(fps)
                        HapticManager.selectionChanged()
                    } label: {
                        Text("\(fps)")
                            .font(.system(size: 10, weight: isActive ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(isActive ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isActive ? Color.yellow : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Slow-Mo button (when device supports high-FPS)
                if cameraManager.isSlowMotionSupported {
                    let isSlowMo = videoResolution == .slowMo
                    Button {
                        let newRes: VideoResolution = isSlowMo ? .hd1080p : .slowMo
                        videoResolutionRaw = newRes.rawValue
                        if newRes.isSlowMotion {
                            cameraManager.configureForSlowMotion(fps: cameraManager.maxSlowMotionFPS)
                        } else {
                            cameraManager.configureForVideoMode(resolution: newRes)
                        }
                        HapticManager.light()
                    } label: {
                        Text(isSlowMo ? "\(cameraManager.maxSlowMotionFPS)fps" : "Slo-Mo")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isSlowMo ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isSlowMo ? Color.yellow : .white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Resolution toggle
                Button {
                    guard videoResolution != .slowMo else { return }
                    let newRes: VideoResolution = videoResolution == .hd1080p ? .uhd4K : .hd1080p
                    videoResolutionRaw = newRes.rawValue
                    HapticManager.light()
                } label: {
                    Text(videoResolution == .slowMo ? "1080p" : videoResolution.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(videoResolution == .uhd4K ? .yellow : .white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(videoResolution == .uhd4K ? Color.yellow.opacity(0.18) : .white.opacity(0.12),
                                    in: Capsule())
                }
                .buttonStyle(.plain)

                // Codec badge (ProRes-capable devices only)
                if cameraManager.isProResRecordingSupported {
                    let activeCodec = cameraManager.captureSettings.videoSettings.codec
                    Button {
                        let codecs = VideoCodec.allCases
                        let idx = codecs.firstIndex(where: { $0 == activeCodec }) ?? 0
                        cameraManager.captureSettings.videoSettings.codec = codecs[(idx + 1) % codecs.count]
                        HapticManager.light()
                    } label: {
                        Text(activeCodec.rawValue)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(activeCodec == .proRes ? .yellow : .white.opacity(0.8))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(activeCodec == .proRes ? Color.yellow.opacity(0.18) : .white.opacity(0.12),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Second row: stabilization + color space + HDR
            HStack(spacing: 8) {
                // Stabilization picker
                let stabModes: [StabilizationMode] = [.off, .standard, .cinematic, .auto]
                Menu {
                    ForEach(stabModes) { mode in
                        Button {
                            stabilizationModeRaw = mode.rawValue
                            cameraManager.setVideoStabilizationMode(mode)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(mode.rawValue, systemImage: stabilizationMode == mode ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised.slash")
                            .font(.system(size: 9))
                        Text(stabilizationMode.rawValue)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(stabilizationMode == .off ? .white.opacity(0.5) : .white.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)

                // Color space picker
                let availableSpaces: [VideoColorSpace] = cameraManager.isAppleLogSupported
                    ? VideoColorSpace.allCases
                    : [.sRGB, .p3, .hlg]
                Menu {
                    ForEach(availableSpaces) { cs in
                        Button {
                            videoColorSpaceRaw = cs.rawValue
                            cameraManager.setVideoColorSpace(cs)
                            HapticManager.selectionChanged()
                        } label: {
                            Label(cs.rawValue, systemImage: videoColorSpace == cs ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text(videoColorSpace.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(videoColorSpace != .sRGB ? .cyan : .white.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(videoColorSpace != .sRGB ? Color.cyan.opacity(0.15) : .white.opacity(0.1),
                                    in: Capsule())
                }
                .buttonStyle(.plain)

                // HDR toggle (when device supports HDR formats)
                if cameraManager.isHDRFormatSupported {
                    Button {
                        isHDREnabled.toggle()
                        cameraManager.setHDREnabled(isHDREnabled)
                        HapticManager.light()
                    } label: {
                        Text("HDR")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isHDREnabled ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(isHDREnabled ? Color.yellow : .white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }
}
