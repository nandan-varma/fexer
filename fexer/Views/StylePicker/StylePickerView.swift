import SwiftUI

struct StylePickerView: View {
    @Bindable var stylesViewModel: StylesViewModel
    var isExpanded: Bool
    var onAdjust: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                StyleCategoryView(
                    selectedCategory: $stylesViewModel.selectedCategory,
                    hasSmartStyle: stylesViewModel.stylesManager.isSmartStylesEnabled
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
            }

            // Style thumbnails strip
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    noneButton

                    ForEach(stylesViewModel.stylesForSelectedCategory) { style in
                        StyleThumbnailView(
                            style: style,
                            isSelected: stylesViewModel.activeStyle?.id == style.id,
                            thumbnail: stylesViewModel.thumbnails[style.id],
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    stylesViewModel.activeStyle = style
                                }
                                onAdjust?()
                                HapticManager.selectionChanged()
                            },
                            onLongPress: {
                                // TODO: full-screen before/after preview
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
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(.easeInOut(duration: 0.2), value: stylesViewModel.activeStyle?.id)
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
