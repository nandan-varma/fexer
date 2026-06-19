import SwiftUI

struct StyleBeforeAfterView: View {
    let style: PhotoStyle
    var onDismiss: () -> Void

    @State private var originalImage: UIImage?
    @State private var styledImage: UIImage?
    @State private var splitFraction: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let original = originalImage, let styled = styledImage {
                    splitContent(original: original, styled: styled, in: geo)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    splitFraction = (value.location.x / geo.size.width)
                                        .fxClamped(to: 0.05...0.95)
                                }
                        )

                    beforeAfterLabels(splitX: splitFraction * geo.size.width, width: geo.size.width)
                } else {
                    ProgressView().tint(.white)
                }

                // Header
                VStack {
                    HStack {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        Spacer()
                        Text(style.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 60)
                    Spacer()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear { loadImages() }
    }

    @ViewBuilder
    private func splitContent(original: UIImage, styled: UIImage, in geo: GeometryProxy) -> some View {
        let splitX = splitFraction * geo.size.width

        // Styled image — full background
        Image(uiImage: styled)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()

        // Original image clipped to left of the divider
        Image(uiImage: original)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .frame(width: splitX, alignment: .leading)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)

        // Divider line
        Rectangle()
            .fill(.white.opacity(0.9))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, splitX - 1)
            .allowsHitTesting(false)

        // Drag handle
        Circle()
            .fill(.white)
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: "chevron.left.and.line.vertical.and.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
            )
            .shadow(color: .black.opacity(0.4), radius: 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, splitX - 18)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func beforeAfterLabels(splitX: CGFloat, width: CGFloat) -> some View {
        HStack {
            Text("BEFORE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.leading, 16)
                .opacity(splitX > 80 ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: splitX > 80)
            Spacer()
            Text("AFTER")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(.trailing, 16)
                .opacity(splitX < width - 80 ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: splitX < width - 80)
        }
        .allowsHitTesting(false)
    }

    private func loadImages() {
        let size = UIScreen.main.bounds.size
        StylePreviewRenderer.shared.originalImage(size: size) { self.originalImage = $0 }
        StylePreviewRenderer.shared.thumbnail(for: style, size: size) { self.styledImage = $0 }
    }
}
