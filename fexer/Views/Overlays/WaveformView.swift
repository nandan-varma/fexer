import SwiftUI

/// Luma waveform monitor — spatial per-pixel density map.
/// X axis = horizontal position in the frame (left → right).
/// Y axis = luma level (0% IRE at bottom, 100% IRE at top).
/// Each (column, luma) cell is lit according to how many source pixels
/// fall at that luminance within that horizontal slice.
struct WaveformView: View {
    let data: WaveformData
    /// Zebra high/low thresholds (0–1) shown as horizontal guide lines.
    var highThreshold: Float = 0.95
    var lowThreshold: Float = 0.02

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Canvas { context, size in
                guard !data.isEmpty else { return }

                let w = size.width
                let h = size.height
                let cols = WaveformData.cols
                let rows = WaveformData.rows
                let cellW = w / CGFloat(cols)
                let cellH = h / CGFloat(rows)

                // IRE gridlines at 0%, 20%, 40%, 60%, 80%, 100%
                for pct in stride(from: 0.0, through: 1.0, by: 0.2) {
                    let y = h - CGFloat(pct) * h
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: w, y: y))
                    context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                }

                // Zebra threshold guide lines
                let highY = h - CGFloat(highThreshold) * h
                var highLine = Path()
                highLine.move(to: CGPoint(x: 0, y: highY))
                highLine.addLine(to: CGPoint(x: w, y: highY))
                context.stroke(highLine, with: .color(.red.opacity(0.55)), lineWidth: 0.75)

                let lowY = h - CGFloat(lowThreshold) * h
                var lowLine = Path()
                lowLine.move(to: CGPoint(x: 0, y: lowY))
                lowLine.addLine(to: CGPoint(x: w, y: lowY))
                context.stroke(lowLine, with: .color(Color(red: 0, green: 0.4, blue: 1).opacity(0.55)), lineWidth: 0.75)

                // Density map — draw each lit cell as a colored rectangle
                for col in 0..<cols {
                    for bin in 0..<rows {
                        let density = data[col, bin]
                        guard density > 0.01 else { continue }

                        let x = CGFloat(col) * cellW
                        // bin 0 = 0% IRE (bottom) → y = h; bin rows-1 = 100% (top) → y = 0
                        let y = h - CGFloat(bin + 1) * cellH
                        let lumaPct = Float(bin) / Float(rows - 1)

                        let color: Color
                        if lumaPct >= highThreshold {
                            color = .red
                        } else if lumaPct <= lowThreshold {
                            color = Color(red: 0, green: 0.4, blue: 1)
                        } else {
                            color = Color(red: 0.15, green: 0.85, blue: 0.25)
                        }

                        var cell = Path()
                        cell.addRect(CGRect(x: x, y: y, width: max(1, cellW), height: max(1, cellH)))
                        context.fill(cell, with: .color(color.opacity(Double(density) * 0.85 + 0.1)))
                    }
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
