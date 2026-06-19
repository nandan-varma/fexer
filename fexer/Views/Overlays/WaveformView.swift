import SwiftUI

/// Luma waveform monitor approximated from histogram data.
/// Shows signal distribution vertically (0% IRE at bottom, 100% at top)
/// with horizontal gridlines at 20% intervals.
struct WaveformView: View {
    let data: HistogramData

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { context, size in
                guard !data.luma.isEmpty else { return }

                let w = size.width
                let h = size.height
                let count = data.luma.count
                let maxVal = data.luma.max() ?? 1
                guard maxVal > 0 else { return }

                // IRE gridlines at 20%, 40%, 60%, 80%
                for pct in stride(from: 0.2, through: 0.8, by: 0.2) {
                    let y = h - CGFloat(pct) * h
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: w, y: y))
                    context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                }

                // Waveform — draw each histogram bin as a vertical bar
                for i in 0..<count {
                    let x = CGFloat(i) / CGFloat(count) * w
                    let intensity = CGFloat(data.luma[i]) / CGFloat(maxVal)
                    let barH = intensity * h

                    // Color the waveform: green for normal, red above 95%, blue below 2%
                    let pct = CGFloat(i) / CGFloat(count)
                    let color: Color = pct > 0.95 ? .red : pct < 0.02 ? Color(red: 0, green: 0.4, blue: 1) : Color(red: 0.2, green: 0.9, blue: 0.2)

                    var bar = Path()
                    bar.addRect(CGRect(x: x, y: h - barH, width: max(1, w / CGFloat(count)), height: barH))
                    context.fill(bar, with: .color(color.opacity(0.7)))
                }
            }

            Text("WFM")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.yellow)
                .padding(.leading, 4)
                .padding(.bottom, 2)
        }
        .frame(width: 120, height: 80)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
}
