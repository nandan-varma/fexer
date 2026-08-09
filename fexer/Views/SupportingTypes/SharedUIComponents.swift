import SwiftUI
import UIKit

// Shared chrome for the full-screen photo pages (review, carousel, gallery)
// and the permission-denied placeholders.

/// 36×36 circular button with a dimmed black background, as used in review top bars.
struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 16
    var weight: Font.Weight = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
        }
    }
}

/// Trash button with the standard "Delete this photo?" confirmation dialog.
struct ReviewDeleteButton: View {
    @Binding var showConfirmation: Bool
    let onDelete: () -> Void

    var body: some View {
        CircleIconButton(systemName: "trash", size: 18) { showConfirmation = true }
            .confirmationDialog("Delete this photo?", isPresented: $showConfirmation, titleVisibility: .visible) {
                Button("Delete Photo", role: .destructive, action: onDelete)
            }
    }
}

/// ShareLink for JPEG data, rendered as the standard share glyph. Hidden when data is nil.
struct SharePhotoLink: View {
    let data: Data?

    var body: some View {
        if let data {
            ShareLink(item: data, preview: SharePreview("Photo")) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Double-tap to toggle 1×/2× zoom, swipe down >80pt to dismiss. Shared by all
/// full-screen photo pages so the gesture behaviour stays identical.
private struct ReviewGestures: ViewModifier {
    @Binding var magnification: CGFloat
    @Binding var lastMagnification: CGFloat
    let onDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { g in
                        let isVertical = abs(g.translation.height) > abs(g.translation.width)
                        if isVertical && g.translation.height > 80 { onDismiss?() }
                    }
            )
            .onTapGesture(count: 2) {
                let target: CGFloat = magnification > 1.5 ? 1.0 : 2.0
                withAnimation(.spring()) { magnification = target }
                lastMagnification = target
            }
    }
}

extension View {
    func reviewGestures(magnification: Binding<CGFloat>,
                        lastMagnification: Binding<CGFloat>,
                        onDismiss: (() -> Void)?) -> some View {
        modifier(ReviewGestures(magnification: magnification,
                                lastMagnification: lastMagnification,
                                onDismiss: onDismiss))
    }
}

/// Centered icon + title + message + "Open Settings" button for permission-denied states.
/// Caller supplies the background.
struct AccessDeniedView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .thin))
                .foregroundStyle(.white.opacity(0.45))

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.48))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 40)
    }
}
