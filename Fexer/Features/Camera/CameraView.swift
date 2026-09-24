import AVKit
import SwiftUI

struct CameraView: View {
    @Bindable var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: Panel?
    @State private var focusPoint: CGPoint?
    @State private var focusTask: Task<Void, Never>?
    @State private var zoomAnchor: Double?
    @State private var showZoomBadge = false
    @State private var zoomBadgeTask: Task<Void, Never>?
    @State private var controlsCategory: ManualControls.Category = .exposure
    @State private var dragAnchor: Double?
    enum Panel: String, Identifiable { case styles, controls, settings, library; var id: Self { self } }
    private let controlsPanelHeight: CGFloat = 300

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
        .task { await model.library.load(); await model.start() }
        .onChange(of: scenePhase) { _, phase in
            Task { if phase == .active { await model.start() } else { await model.stop() } }
        }
        .onChange(of: model.recipe) { model.updatePreview() }
        .onChange(of: model.mode) { model.updatePreview() }
        .onChange(of: model.controls) { model.updateControls() }
        .onChange(of: model.preferences.value) {
            model.updatePreview()
            model.location.setEnabled(model.preferences.value.location && scenePhase == .active)
            model.level.setEnabled(model.preferences.value.level && scenePhase == .active)
        }
        .onCameraCaptureEvent(isEnabled: sheet == nil && model.phase == .ready) { event in
            if event.phase == .ended { model.shutter() }
        }
        .sheet(item: $sheet) { panel in
            switch panel {
            case .styles: StylePicker(recipe: $model.recipe, renderer: model.library.renderer, source: nil)
            case .controls:
                ManualControls(model: model, initialCategory: controlsCategory)
                    .presentationDetents([.height(controlsPanelHeight), .medium])
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(controlsPanelHeight)))
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
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

    private var header: some View {
        HStack {
            Text("fexer").font(.system(size: 29, weight: .semibold, design: .serif)).tracking(-1.5).accessibilityLabel("Fexer camera")
            Spacer()
            #if targetEnvironment(simulator)
            Text("SAMPLE CAMERA").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Theme.muted)
            #endif
            IconButton(label: "Settings", symbol: "gearshape") { sheet = .settings }.accessibilityIdentifier("settings")
        }.padding(.leading, 22).padding(.trailing, 10).frame(height: 48)
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
                active: model.controls.manualExposure, onTap: openExposure, onDrag: isoDrag
            ).accessibilityLabel("ISO, drag to adjust").accessibilityIdentifier("manualControls")
            controlPill(
                CameraText.shutter(model.controls.manualExposure ? model.controls.shutter : model.reading.shutter),
                active: model.controls.manualExposure, onTap: openExposure, onDrag: shutterDrag
            ).accessibilityLabel("Shutter speed, drag to adjust")
            controlPill(
                model.controls.manualWhiteBalance ? "\(Int(model.controls.temperature))K" : "AWB",
                active: model.controls.manualWhiteBalance, onTap: openWhiteBalance, onDrag: temperatureDrag
            ).accessibilityLabel("White balance, drag to adjust")
            controlPill(
                model.controls.manualFocus ? "MF \(model.controls.focus.formatted(.percent.precision(.fractionLength(0))))" : "AF",
                active: model.controls.manualFocus, onTap: openFocus, onDrag: focusDrag
            ).accessibilityLabel("Focus, drag to adjust")
            Spacer(minLength: 0)
            IconButton(label: "Zoom, presets & torch", symbol: "ellipsis.circle", selected: model.controls.torch) { controlsCategory = .camera; sheet = .controls }
        }.foregroundStyle(.white).padding(.horizontal, 14).disabled(!model.activity.isIdle)
    }

    /// Pills double as sliders: tap opens the full sheet (already in manual mode), drag adjusts
    /// in place without leaving the viewfinder — the point of a pro top bar is not burying values
    /// behind an extra "enable manual" toggle.
    private func controlPill(_ text: String, active: Bool, onTap: @escaping () -> Void, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Button(action: onTap) {
            Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(active ? Theme.accent : .white)
                .padding(.horizontal, 8).frame(minWidth: 46, minHeight: 32)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(active ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { onDrag($0.translation.height) }
                .onEnded { _ in dragAnchor = nil }
        )
    }

    private func openExposure() { model.controls.manualExposure = true; controlsCategory = .exposure; sheet = .controls }
    private func openWhiteBalance() { model.controls.manualWhiteBalance = true; controlsCategory = .whiteBalance; sheet = .controls }
    private func openFocus() { model.controls.manualFocus = true; controlsCategory = .focus; sheet = .controls }

    private func isoDrag(_ translationY: CGFloat) {
        let range = model.capabilities.isoRange
        let logRange = log2(range.lowerBound)...log2(range.upperBound)
        if dragAnchor == nil {
            let start = (model.controls.manualExposure ? model.controls.iso : model.reading.iso).bounded(range)
            model.controls.manualExposure = true
            model.controls.iso = start
            dragAnchor = log2(start)
        }
        model.controls.iso = pow(2, (dragAnchor! - translationY / 220 * (logRange.upperBound - logRange.lowerBound)).bounded(logRange))
    }
    private func shutterDrag(_ translationY: CGFloat) {
        let range = model.capabilities.shutterRange
        let logRange = log2(range.lowerBound)...log2(range.upperBound)
        if dragAnchor == nil {
            let start = (model.controls.manualExposure ? model.controls.shutter : model.reading.shutter).bounded(range)
            model.controls.manualExposure = true
            model.controls.shutter = start
            dragAnchor = log2(start)
        }
        model.controls.shutter = pow(2, (dragAnchor! - translationY / 220 * (logRange.upperBound - logRange.lowerBound)).bounded(logRange))
    }
    private func temperatureDrag(_ translationY: CGFloat) {
        let range: ClosedRange<Double> = 2500...10000
        if dragAnchor == nil {
            let start = (model.controls.manualWhiteBalance ? model.controls.temperature : model.reading.temperature).bounded(range)
            model.controls.manualWhiteBalance = true
            model.controls.temperature = start
            dragAnchor = start
        }
        model.controls.temperature = (dragAnchor! - translationY / 220 * (range.upperBound - range.lowerBound)).bounded(range)
    }
    private func focusDrag(_ translationY: CGFloat) {
        let range: ClosedRange<Double> = 0...1
        if dragAnchor == nil {
            let start = (model.controls.manualFocus ? model.controls.focus : model.reading.focus).bounded(range)
            model.controls.manualFocus = true
            model.controls.focus = start
            dragAnchor = start
        }
        model.controls.focus = (dragAnchor! - translationY / 220 * (range.upperBound - range.lowerBound)).bounded(range)
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
                Button { sheet = .library } label: {
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
                        IconButton(label: "Photo styles", symbol: "camera.filters", selected: model.recipe.styleID != "original") { sheet = .styles }.accessibilityIdentifier("styles")
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
                zoomAnchor = base
                model.controls.zoom = (base * value.magnification).bounded(model.capabilities.zoomRange, fallback: base)
                showZoomBadge = true
                zoomBadgeTask?.cancel()
            }
            .onEnded { _ in
                zoomAnchor = nil
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
