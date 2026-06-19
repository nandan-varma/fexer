import SwiftUI

struct StyleThumbnailView: View {
    let style: PhotoStyle
    let isSelected: Bool
    let thumbnail: UIImage?
    var suggestedStyle: PhotoStyle?
    var onSelect: (() -> Void)?
    var onLongPress: (() -> Void)?

    private var isSuggested: Bool {
        suggestedStyle?.id == style.id
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // Thumbnail image or gradient placeholder
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholderGradient
                }

                // Black & white badge for BW styles
                if style.name.contains("BW") || style.name == "Noir BW" {
                    Text("BW")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                // Scene suggestion badge — shown when this style matches the classifier output
                if isSuggested {
                    ZStack {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 18, height: 18)
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.yellow : .clear, lineWidth: 2.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
            .scaleEffect(isSelected ? 1.06 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)

            Text(style.name)
                .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .yellow : .white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 72)
        }
        .onTapGesture { onSelect?() }
        .onLongPressGesture { onLongPress?() }
    }

    private var placeholderGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    style.category == .film ? Color(red: 0.8, green: 0.7, blue: 0.5) :
                    style.category == .genre ? Color(red: 0.3, green: 0.6, blue: 0.4) :
                    Color(red: 0.4, green: 0.3, blue: 0.7),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ProgressView()
                .tint(.white.opacity(0.6))
                .scaleEffect(0.7)
        }
    }
}
