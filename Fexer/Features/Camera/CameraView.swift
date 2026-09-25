import AVKit
import SwiftUI
import UIKit

struct CameraView: View {
    @Bindable var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: Panel?
    @State private var focusPoint: CGPoint?
    @State private var focusTask: Task<Void, Never>?
    @State private var zoomAnchor: Double?
    @State private var zoomHapticWhole: Int?
    @State private var showZoomBadge = false
    @State private var zoomBadgeTask: Task<Void, Never>?
    @State private var expanded: ExpandedControl?
    @State private var dragAnchor: Double?
    @State private var dragHapticStep: Int?
    @State private var dragAtLimit = false
    enum Panel: String, Identifiable { case styles, settings, library; var id: Self { self } }
    enum ExpandedControl: Equatable { case iso, shutter, whiteBalance, focus }

    var body: some View {
        GeometryReader { geometry in
            let previewHeight = min(geometry.size.width * 4 / 3, max(220, geometry.size.height - 254))
            VStack(spacing: 0) {
                header
                quickControls
                viewfinder
                    .frame(height: previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                captureControls
                Spacer(minLength: 0)
            }
            .background(Theme.background)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .environment(\.hapticsEnabled, model.preferences.value.haptics)
        .task {
            // Independent actors (CaptureStore vs. CameraService) — no reason to make the
            // camera wait on the library's disk scan before it starts warming up.
            async let library: Void = model.library.load()
            async let camera: Void = model.start()
            _ = await (library, camera)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { if phase == .active { await model.start() } else { await model.stop() } }
        }
        .onChange(of: model.recipe) { model.updatePreview() }
        .onChange(of: model.mode) { model.updatePreview(); model.updateCaptureMode() }
        .onChange(of: model.controls) { model.updateControls() }
        .onChange(of: model.preferences.value) {
            model.updatePreview()
            model.updateCaptureMode()
            model.location.setEnabled(model.preferences.value.location && scenePhase == .active)
            model.level.setEnabled(model.preferences.value.level && scenePhase == .active)
        }
        .onCameraCaptureEvent(isEnabled: sheet == nil && model.phase == .ready) { event in
            if event.phase == .ended { model.shutter() }
        }
        .sheet(item: $sheet) { panel in
            switch panel {
            case .styles: StylePicker(recipe: $model.recipe, renderer: model.library.renderer, source: nil)
            case .settings: SettingsView(preferences: model.preferences, capabilities: model.capabilities, library: model.library, ratio: $model.recipe.ratio)
            case .library: LibraryView(library: model.library)
            }
        }
        .sheet(item: $model.review) { item in
            NavigationStack { CaptureDetail(item: item, library: model.library) }
        }
        .issueAlert($model.issue)
        .overlay(alignment: .bottom) {
            if model.pendingCapture != nil, model.activity.isIdle {
                Button { Task { await model.retrySave() } } label: { Label("Retry save · capture held in memory", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") }
                    .buttonStyle(.borderedProminent).padding()
            }
        }
    }

    /// The header normally just shows the wordmark and settings gear — real estate that sits
    /// idle most of the time. Tapping (or dragging) a control pill below repurposes it as that
    /// control's full-width scrubber instead of opening a sheet that would cover the viewfinder.
    private var header: some View {
        HStack(spacing: 10) {
            if let expanded {
                expandedScrubber(expanded).frame(maxWidth: .infinity)
                Button("AUTO") { setAuto(expanded) }
                    .font(.system(size: 11, weight: .semibold)).tracking(1)
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("autoControl")
                Button { self.expanded = nil } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).accessibilityLabel("Collapse control").accessibilityIdentifier("collapseControl")
            } else {
                Text("fexer").font(.system(size: 29, weight: .semibold, design: .serif)).tracking(-1.5).accessibilityLabel("Fexer camera")
                Spacer()
                #if targetEnvironment(simulator)
                Text("SAMPLE CAMERA").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Theme.muted)
                #endif
                IconButton(label: "Settings", symbol: "gearshape") { sheet = .settings }.accessibilityIdentifier("settings")
            }
        }.padding(.leading, 22).padding(.trailing, 10).frame(height: 48)
    }

    /// Real gradations for each pill's expanded scrubber: ISO/shutter tick in third-stops over a
    /// log2 domain (how exposure actually works), white balance ticks every 100K, focus every 2%.
    @ViewBuilder private func expandedScrubber(_ control: ExpandedControl) -> some View {
        switch control {
        case .iso:
            let range = model.capabilities.isoRange
            let logRange = log2(range.lowerBound)...log2(range.upperBound)
            HapticScrubber(
                title: "ISO",
                value: Binding(get: { log2(model.controls.iso.bounded(range)) }, set: { model.controls.iso = pow(2, $0) }),
                range: logRange, display: "ISO \(Int(model.controls.iso))",
                minorStep: 1.0 / 3, majorEvery: 3, compact: true
            )
        case .shutter:
            let range = model.capabilities.shutterRange
            let logRange = log2(range.lowerBound)...log2(range.upperBound)
            HapticScrubber(
                title: "Shutter",
                value: Binding(get: { log2(model.controls.shutter.bounded(range)) }, set: { model.controls.shutter = pow(2, $0) }),
                range: logRange, display: CameraText.shutter(model.controls.shutter),
                minorStep: 1.0 / 3, majorEvery: 3, compact: true
            )
        case .whiteBalance:
            HapticScrubber(
                title: "White balance", value: $model.controls.temperature, range: 2500...10000,
                display: "\(Int(model.controls.temperature))K", minorStep: 100, majorEvery: 5, compact: true
            )
        case .focus:
            HapticScrubber(
                title: "Focus", value: $model.controls.focus, range: 0...1,
                display: model.controls.focus.formatted(.percent.precision(.fractionLength(0))),
                minorStep: 0.02, majorEvery: 10, compact: true
            )
        }
    }

    private func setAuto(_ control: ExpandedControl) {
        switch control {
        case .iso, .shutter: model.controls.manualExposure = false
        case .whiteBalance: model.controls.manualWhiteBalance = false
        case .focus: model.controls.manualFocus = false
        }
        expanded = nil
    }

    /// Tapping a pill again while it's expanded just collapses it (the value/mode is kept);
    /// tapping a different pill switches which one is expanded.
    private func toggleExpanded(_ control: ExpandedControl, enable: () -> Void) {
        if expanded == control { expanded = nil }
        else { enable(); expanded = control }
    }

    private var quickControls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Flash", selection: $model.preferences.value.flash) {
                    ForEach(FlashSetting.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { Image(systemName: model.preferences.value.flash.symbol).frame(width: 32, height: 32) }
                .accessibilityLabel("Flash, \(model.preferences.value.flash.rawValue)").disabled(!model.capabilities.supportsFlash)
            Spacer(minLength: 0)
            controlPill(
                "ISO \(Int(model.controls.manualExposure ? model.controls.iso : model.reading.iso))",
                active: model.controls.manualExposure, expanded: expanded == .iso, identifier: "isoControl",
                onTap: openISO, onDrag: isoDrag
            ).accessibilityLabel("ISO, drag to adjust")
            controlPill(
                CameraText.shutter(model.controls.manualExposure ? model.controls.shutter : model.reading.shutter),
                active: model.controls.manualExposure, expanded: expanded == .shutter, identifier: "shutterControl",
                onTap: openShutter, onDrag: shutterDrag
            ).accessibilityLabel("Shutter speed, drag to adjust")
            controlPill(
                model.controls.manualWhiteBalance ? "\(Int(model.controls.temperature))K" : "AWB",
                active: model.controls.manualWhiteBalance, expanded: expanded == .whiteBalance, identifier: "whiteBalanceControl",
                onTap: openWhiteBalance, onDrag: temperatureDrag
            ).accessibilityLabel("White balance, drag to adjust")
            controlPill(
                model.controls.manualFocus ? "MF \(model.controls.focus.formatted(.percent.precision(.fractionLength(0))))" : "AF",
                active: model.controls.manualFocus, expanded: expanded == .focus, identifier: "focusControl",
                onTap: openFocus, onDrag: focusDrag
            ).accessibilityLabel("Focus, drag to adjust")
            Spacer(minLength: 0)
            if model.capabilities.supportsTorch {
                IconButton(
                    label: model.controls.torch ? "Turn off continuous light" : "Turn on continuous light",
                    symbol: model.controls.torch ? "flashlight.on.fill" : "flashlight.off.fill", selected: model.controls.torch
                ) { model.controls.torch.toggle() }
            }
        }.foregroundStyle(.white).padding(.horizontal, 14).disabled(!model.activity.isIdle)
    }

    /// Pills double as sliders: tap expands this control's own scrubber in the header above
    /// (never a sheet that would cover the viewfinder), drag adjusts in place immediately.
    private func controlPill(_ text: String, active: Bool, expanded: Bool, identifier: String, onTap: @escaping () -> Void, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Button(action: onTap) {
            Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(expanded ? Theme.background : (active ? Theme.accent : .white))
                .padding(.horizontal, 8).frame(minWidth: 46, minHeight: 32)
                .background(expanded ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(!expanded && active ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { onDrag($0.translation.height) }
                .onEnded { _ in dragAnchor = nil; dragHapticStep = nil; dragAtLimit = false }
        )
    }

    /// Mirrors HapticScrubber's feel: a selection tick per quantized step, a firmer thud at the
    /// rail, so dragging a top-bar pill feels the same as scrubbing the sheet's full control.
    private func fireDragHaptic(normalized: Double, steps: Int = 40) {
        guard model.preferences.value.haptics else { return }
        let step = Int((normalized.bounded(0...1) * Double(steps)).rounded())
        if step != dragHapticStep {
            dragHapticStep = step
            UISelectionFeedbackGenerator().selectionChanged()
        }
        let reachedLimit = normalized <= 0 || normalized >= 1
        if reachedLimit, !dragAtLimit { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6) }
        dragAtLimit = reachedLimit
    }

    private func openISO() { toggleExpanded(.iso) { model.controls.manualExposure = true } }
    private func openShutter() { toggleExpanded(.shutter) { model.controls.manualExposure = true } }
    private func openWhiteBalance() { toggleExpanded(.whiteBalance) { model.controls.manualWhiteBalance = true } }
    private func openFocus() { toggleExpanded(.focus) { model.controls.manualFocus = true } }

    private func isoDrag(_ translationY: CGFloat) {
        let range = model.capabilities.isoRange
        let logRange = log2(range.lowerBound)...log2(range.upperBound)
        if dragAnchor == nil {
            let start = (model.controls.manualExposure ? model.controls.iso : model.reading.iso).bounded(range)
            model.controls.manualExposure = true
            model.controls.iso = start
            dragAnchor = log2(start)
            expanded = .iso
        }
        let boundedLog = (dragAnchor! - translationY / 220 * (logRange.upperBound - logRange.lowerBound)).bounded(logRange)
        model.controls.iso = pow(2, boundedLog)
        fireDragHaptic(normalized: (boundedLog - logRange.lowerBound) / (logRange.upperBound - logRange.lowerBound))
    }
    private func shutterDrag(_ translationY: CGFloat) {
        let range = model.capabilities.shutterRange
        let logRange = log2(range.lowerBound)...log2(range.upperBound)
        if dragAnchor == nil {
            let start = (model.controls.manualExposure ? model.controls.shutter : model.reading.shutter).bounded(range)
            model.controls.manualExposure = true
            model.controls.shutter = start
            dragAnchor = log2(start)
            expanded = .shutter
        }
        let boundedLog = (dragAnchor! - translationY / 220 * (logRange.upperBound - logRange.lowerBound)).bounded(logRange)
        model.controls.shutter = pow(2, boundedLog)
        fireDragHaptic(normalized: (boundedLog - logRange.lowerBound) / (logRange.upperBound - logRange.lowerBound))
    }
    private func temperatureDrag(_ translationY: CGFloat) {
        let range: ClosedRange<Double> = 2500...10000
        if dragAnchor == nil {
            let start = (model.controls.manualWhiteBalance ? model.controls.temperature : model.reading.temperature).bounded(range)
            model.controls.manualWhiteBalance = true
            model.controls.temperature = start
            dragAnchor = start
            expanded = .whiteBalance
        }
        let bounded = (dragAnchor! - translationY / 220 * (range.upperBound - range.lowerBound)).bounded(range)
        model.controls.temperature = bounded
        fireDragHaptic(normalized: (bounded - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
    private func focusDrag(_ translationY: CGFloat) {
        let range: ClosedRange<Double> = 0...1
        if dragAnchor == nil {
            let start = (model.controls.manualFocus ? model.controls.focus : model.reading.focus).bounded(range)
            model.controls.manualFocus = true
            model.controls.focus = start
            dragAnchor = start
            expanded = .focus
        }
        let bounded = (dragAnchor! - translationY / 220 * (range.upperBound - range.lowerBound)).bounded(range)
        model.controls.focus = bounded
        fireDragHaptic(normalized: (bounded - range.lowerBound) / (range.upperBound - range.lowerBound), steps: 20)
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                CameraPreview(frames: model.frames)
                CompositionGrid(style: model.preferences.value.grid)
                if model.recipe.ratio != .original, model.mode != .video {
                    let crop = CropGeometry.crop(in: CGRect(origin: .zero, size: geometry.size), aspect: model.recipe.ratio.portraitAspect, zoom: 1, x: 0.5, y: 0.5)
                    Path { path in path.addRect(CGRect(origin: .zero, size: geometry.size)); path.addRect(crop) }
                        .fill(.black.opacity(0.65), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                }
                if let point = focusPoint {
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1.5).frame(width: 65, height: 65).position(point).allowsHitTesting(false)
                }
                phaseOverlay
                if model.preferences.value.level, model.phase == .ready { LevelIndicator(roll: model.level.roll) }
                if showZoomBadge {
                    Text(String(format: "%.1f×", model.controls.zoom))
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                if case .countdown(let count) = model.activity {
                    Text(count.formatted()).font(.system(size: 84, weight: .light, design: .rounded)).shadow(radius: 20).accessibilityLabel("Capture in \(count)")
                }
                VStack {
                    HStack(alignment: .top) {
                        if model.preferences.value.monitor != .off { ScopeView(frames: model.frames, monitor: model.preferences.value.monitor) }
                        Spacer()
                        if model.controls.exposureLocked { Label("AE LOCK", systemImage: "lock.fill").font(.caption2).padding(8).background(.black.opacity(0.6), in: Capsule()) }
                        if case .recording(let start) = model.activity {
                            HStack { Circle().fill(.red).frame(width: 7, height: 7); Text(start, style: .timer).monospacedDigit() }
                                .font(.caption).padding(8).background(.black.opacity(0.7), in: Capsule())
                        }
                    }
                    Spacer()
                    if model.phase == .ready {
                        HStack(spacing: 8) {
                            ForEach(model.capabilities.lenses.filter { !$0.isFront }) { lens in
                                Button { Task { await model.selectLens(lens) } } label: {
                                    Text(lens.label).font(.system(.caption, design: .monospaced).weight(.semibold))
                                        .frame(minWidth: 44, minHeight: 44)
                                        .background(.black.opacity(0.55), in: Circle())
                                }.tint(model.capabilities.activeLensID == lens.id ? Theme.accent : .white)
                                    .accessibilityLabel(lens.name + " camera").disabled(!model.activity.isIdle)
                            }
                        }
                    }
                }.padding(14)
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard model.phase == .ready else { return }
                focusPoint = point; model.focus(point, size: geometry.size)
                focusTask?.cancel()
                focusTask = Task { do { try await Task.sleep(for: .seconds(1.5)); focusPoint = nil } catch {} }
            }
            .simultaneousGesture(zoomGesture)
            .animation(.easeOut(duration: 0.2), value: showZoomBadge)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera viewfinder. Tap to focus, pinch to zoom.")
        }
    }

    @ViewBuilder private var phaseOverlay: some View {
        switch model.phase {
        case .starting, .idle: ProgressView("Opening camera").padding().background(.ultraThinMaterial, in: Capsule())
        case .denied:
            ContentUnavailableView {
                Label("Your camera, your view", systemImage: "camera")
            } description: { Text("Allow camera access in Settings to start shooting. You can still import and edit photos in your library.") }
            actions: { Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent) }
        case .failed(let message):
            ContentUnavailableView { Label("Camera paused", systemImage: "camera.badge.ellipsis") }
                description: { Text(message) } actions: { Button("Try again") { Task { await model.start() } }.buttonStyle(.borderedProminent) }
        case .interrupted: Label("Camera temporarily unavailable", systemImage: "pause.circle").padding().background(.ultraThinMaterial, in: Capsule())
        case .ready: EmptyView()
        }
    }

    private var captureControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 24) {
                ForEach([CaptureMode.photo, .video]) { mode in
                    Button(mode.rawValue.uppercased()) { model.mode = mode }
                        .font(.system(size: 11, weight: .semibold)).tracking(1.5)
                        .tint(model.mode == mode ? Theme.accent : Theme.muted).frame(minHeight: 38)
                }
                Menu {
                    ForEach([CaptureMode.burst, .lightTrails, .interval]) { mode in Button(mode.rawValue) { model.mode = mode } }
                } label: {
                    HStack(spacing: 4) { Text([CaptureMode.photo, .video].contains(model.mode) ? "MORE" : model.mode.rawValue.uppercased()); Image(systemName: "chevron.down").font(.system(size: 8)) }
                        .font(.system(size: 11, weight: .semibold)).tracking(1).frame(minHeight: 38)
                }.tint([CaptureMode.photo, .video].contains(model.mode) ? Theme.muted : Theme.accent)
            }.disabled(!model.activity.isIdle)
            HStack {
                Button { expanded = nil; sheet = .library } label: {
                    Group {
                        if let item = model.library.items.first { CaptureThumbnail(item: item, library: model.library).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)) }
                        else { Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 48, height: 48).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12)) }
                    }.overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2), lineWidth: 1))
                }.accessibilityLabel("Photo library").accessibilityIdentifier("library")
                Spacer()
                Button { model.shutter() } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(model.phase == .ready ? 0.9 : 0.3), lineWidth: 3).frame(width: 76, height: 76)
                        if model.activity.isIdle {
                            Circle().fill(model.mode == .video ? .red : .white).frame(width: 64, height: 64)
                        } else if model.activity == .capturing || model.activity == .finishing { ProgressView().tint(.white) }
                        else { RoundedRectangle(cornerRadius: 5).fill(model.activity.isRecording ? .red : Theme.accent).frame(width: 28, height: 28) }
                    }
                }.buttonStyle(.plain).accessibilityLabel(model.activity.isIdle ? "Capture \(model.mode.rawValue.lowercased())" : "Stop capture")
                    .accessibilityIdentifier("shutter").disabled(model.phase != .ready || model.pendingCapture != nil)
                Spacer()
                VStack(spacing: 0) {
                    if model.mode == .video {
                        IconButton(label: "Switch camera", symbol: "arrow.triangle.2.circlepath.camera") { flip() }
                    } else {
                        IconButton(label: "Photo styles", symbol: "camera.filters", selected: model.recipe.styleID != "original") { expanded = nil; sheet = .styles }.accessibilityIdentifier("styles")
                    }
                }.frame(width: 48)
            }.padding(.horizontal, 36)
            HStack {
                Text(model.mode == .video ? "Video · natural color" : PhotoStyle.find(model.recipe.styleID).name)
                    .lineLimit(1)
                Spacer()
                if case .sequence(let count) = model.activity { Text("\(count) captured · tap to stop") }
                else if model.mode != .video { Text(model.recipe.ratio.rawValue).monospacedDigit() }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 24).padding(.top, 6)
            if model.mode == .lightTrails { Text("Keep steady · \(Int(model.preferences.value.trailSeconds))s · preview resolution").font(.caption2).foregroundStyle(Theme.accent) }
        }
    }
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard model.phase == .ready else { return }
                let base = zoomAnchor ?? model.controls.zoom
                if zoomAnchor == nil { zoomHapticWhole = Int(base) }
                zoomAnchor = base
                model.controls.zoom = (base * value.magnification).bounded(model.capabilities.zoomRange, fallback: base)
                let whole = Int(model.controls.zoom)
                if whole != zoomHapticWhole, model.preferences.value.haptics {
                    zoomHapticWhole = whole
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                showZoomBadge = true
                zoomBadgeTask?.cancel()
            }
            .onEnded { _ in
                zoomAnchor = nil
                zoomHapticWhole = nil
                zoomBadgeTask = Task {
                    try? await Task.sleep(for: .seconds(1))
                    showZoomBadge = false
                }
            }
    }
    private func flip() {
        if let lens = model.capabilities.lenses.first(where: { $0.isFront != model.capabilities.isFront }) { Task { await model.selectLens(lens) } }
    }
    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
}
