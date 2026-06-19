import SwiftUI

struct StylePickerView: View {
    @Bindable var stylesViewModel: StylesViewModel
    var isExpanded: Bool
    var onAdjust: (() -> Void)?

    @AppStorage("styleIntensity") private var storedIntensity: Double = 1.0

    private var stylesManager: StylesManager { stylesViewModel.stylesManager }

    private var activeSuggestedStyle: PhotoStyle? {
        guard stylesManager.isSmartStylesEnabled else { return nil }
        return stylesManager.suggestedStyle
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                StyleCategoryView(
                    selectedCategory: $stylesViewModel.selectedCategory,
                    hasSmartStyle: stylesManager.isSmartStylesEnabled
                )
                .padding(.vertical, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Adjustment dials — appear when a style is active
            if stylesViewModel.activeStyle != nil {
                StyleAdjustmentsRow(
                    adjustments: Binding(
                        get: { stylesViewModel.adjustments },
                        set: {
                            stylesViewModel.adjustments = $0
                            onAdjust?()
                        }
                    ),
                    isBW: stylesViewModel.activeStyleIsBW
                )
                .transition(.move(edge: .top).combined(with: .opacity))

                StyleIntensitySlider(intensity: Binding(
                    get: { Float(storedIntensity) },
                    set: { newValue in
                        storedIntensity = Double(newValue)
                        stylesManager.styleIntensity = newValue
                        onAdjust?()
                    }
                ))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Scene suggestion label
            if let suggested = activeSuggestedStyle {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Suggested for scene")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                }
                .foregroundStyle(Color.yellow)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(suggested.id)
            }

            thumbnailStrip
        }
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(.easeInOut(duration: 0.2), value: stylesViewModel.activeStyle?.id)
        .onAppear {
            // Sync persisted intensity into the model on first appearance
            stylesManager.styleIntensity = Float(storedIntensity)
        }
    }

    private var thumbnailStrip: some View {
        let suggested = activeSuggestedStyle
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                noneButton

                ForEach(stylesViewModel.stylesForSelectedCategory) { style in
                    StyleThumbnailView(
                        style: style,
                        isSelected: stylesViewModel.activeStyle?.id == style.id,
                        thumbnail: stylesViewModel.thumbnails[style.id],
                        suggestedStyle: suggested,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                stylesViewModel.activeStyle = style
                            }
                            onAdjust?()
                            HapticManager.selectionChanged()
                        },
                        onLongPress: {
                            stylesViewModel.isBeforeAfterActive = true
                        }
                    )
                    .onAppear { stylesViewModel.requestThumbnail(for: style) }
                }
            }
            .padding(.horizontal, 16)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: 98)
    }

    private var noneButton: some View {
        VStack(spacing: 5) {
            ZStack {
                Color(white: 0.15)
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(stylesViewModel.activeStyle == nil ? Color.yellow : .clear, lineWidth: 2.5)
            )

            Text("None")
                .font(.system(size: 9, weight: stylesViewModel.activeStyle == nil ? .semibold : .regular))
                .foregroundStyle(stylesViewModel.activeStyle == nil ? .yellow : .white.opacity(0.6))
        }
        .onTapGesture {
            withAnimation { stylesViewModel.activeStyle = nil }
            onAdjust?()
            HapticManager.selectionChanged()
        }
    }
}

private struct StyleIntensitySlider: View {
    @Binding var intensity: Float

    @State private var isDragging = false
    @State private var dragStart: Float = 0

    var body: some View {
        HStack(spacing: 10) {
            Text("STRENGTH")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(1)

            GeometryReader { geo in
                let w = geo.size.width
                let pos = CGFloat(intensity) * w

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.10))
                        .frame(height: 3)

                    Capsule()
                        .fill(Color.yellow.opacity(isDragging ? 1.0 : 0.8))
                        .frame(width: pos, height: 3)

                    Circle()
                        .fill(isDragging ? Color.yellow : .white)
                        .frame(width: isDragging ? 9 : 6, height: isDragging ? 9 : 6)
                        .offset(x: pos - (isDragging ? 4.5 : 3))
                        .animation(.easeInOut(duration: 0.12), value: isDragging)
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle().size(CGSize(width: w, height: 24)))
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if !isDragging {
                                isDragging = true
                                dragStart = intensity
                                HapticManager.light()
                            }
                            let raw = dragStart + Float(g.translation.width / w)
                            intensity = raw.fxClamped(to: 0.0...1.0)
                        }
                        .onEnded { _ in
                            withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
                        }
                )
            }
            .frame(height: 16)

            Text("\(Int(intensity * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(intensity >= 0.999 ? .white.opacity(0.4) : .yellow)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                intensity = 1.0
            }
            HapticManager.light()
        }
    }
}
