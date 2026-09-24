import SwiftUI

/// Vertical stereo VU meter for video recording monitoring.
/// Mirrors the audio level published by CameraManager.audioLevel.
struct AudioLevelMeterView: View {
    let level: Float  // 0.0 (silence) … 1.0 (peak/clipping)

    private let barCount = 14

    var body: some View {
        HStack(spacing: 2) {
            meter(level: level)
            meter(level: level * 0.92)  // slight L/R divergence for visual interest
        }
        .frame(width: 14, height: 60)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func meter(level: Float) -> some View {
        VStack(spacing: 1) {
            ForEach((0..<barCount).reversed(), id: \.self) { i in
                let threshold = Float(i) / Float(barCount - 1)
                let lit = level >= threshold
                let color: Color = i >= barCount - 2 ? .red :
                                   i >= barCount - 4 ? .yellow : .green
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? color : color.opacity(0.15))
                    .frame(width: 5, height: 3)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black
        HStack(spacing: 16) {
            AudioLevelMeterView(level: 0.3)
            AudioLevelMeterView(level: 0.7)
            AudioLevelMeterView(level: 0.95)
        }
    }
}
