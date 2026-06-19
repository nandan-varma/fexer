import SwiftUI

// MARK: - Swipe-Up Hint

struct SwipeUpHintView: View {
    @State private var floatOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
            Text("MANUAL CONTROLS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .offset(y: floatOffset)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                floatOffset = -5
            }
        }
    }
}

// MARK: - Brightness Zone Hint

struct BrightnessHintView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 2, height: 72)

            Text("EV")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Live Brightness EV Indicator

struct BrightnessEVIndicator: View {
    let ev: Float

    private let trackHeight: CGFloat = 160

    private var thumbY: CGFloat {
        let normalized = CGFloat((ev + 3) / 6)  // 0 at −3 EV, 1 at +3 EV
        return trackHeight * (1 - normalized)
    }

    private var accentColor: Color {
        if ev > 0.15  { return .yellow }
        if ev < -0.15 { return Color(red: 0.3, green: 0.9, blue: 1.0) }
        return .white
    }

    private var label: String {
        if abs(ev) < 0.05 { return "0 EV" }
        return String(format: "%+.1f EV", ev)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Numeric label aligned to thumb
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: Capsule())
                .offset(y: thumbY - trackHeight / 2)
                .animation(.interactiveSpring(), value: ev)

            // Track + thumb
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(width: 3, height: trackHeight)

                // Center mark at 0 EV
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 8, height: 1)
                    .offset(y: trackHeight / 2 - 0.5)

                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: accentColor.opacity(0.5), radius: 4)
                    .offset(y: thumbY - 5)
                    .animation(.interactiveSpring(), value: ev)
            }
            .frame(width: 10, height: trackHeight)
        }
    }
}
