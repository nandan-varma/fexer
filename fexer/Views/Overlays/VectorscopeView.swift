import SwiftUI

/// Vectorscope overlay showing colour distribution on a chroma wheel.
/// Points are rendered as a heatmap cloud from sampled luma data.
/// Full vectorscope requires per-pixel RGB analysis; this version
/// visualises the R–B (warmth) and R–G (hue tilt) balance from histogram data.
struct VectorscopeView: View {
    var redData:   [Float] = []
    var greenData: [Float] = []
    var blueData:  [Float] = []

    var body: some View {
        ZStack {
            Canvas { context, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let radius = min(cx, cy) - 4

                // Background circle
                context.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                                     width: radius * 2, height: radius * 2)),
                             with: .color(.black.opacity(0.4)))

                // Ring
                let ring = Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                                   width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(.white.opacity(0.15)), lineWidth: 0.5)

                // Crosshairs
                var hLine = Path()
                hLine.move(to: CGPoint(x: cx - radius, y: cy))
                hLine.addLine(to: CGPoint(x: cx + radius, y: cy))
                context.stroke(hLine, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

                var vLine = Path()
                vLine.move(to: CGPoint(x: cx, y: cy - radius))
                vLine.addLine(to: CGPoint(x: cx, y: cy + radius))
                context.stroke(vLine, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

                // Color target dots at standard vectorscope positions
                let targets: [(String, CGFloat, CGFloat, Color)] = [
                    ("R",  45,  0.75, .red),
                    ("Mg", 75,  0.75, .purple),
                    ("B",  135, 0.75, .blue),
                    ("Cy", 225, 0.75, .cyan),
                    ("G",  285, 0.75, .green),
                    ("Yw", 345, 0.75, .yellow)
                ]
                for (label, angleDeg, dist, color) in targets {
                    let angle = CGFloat(angleDeg) * .pi / 180
                    let x = cx + cos(angle) * radius * dist
                    let y = cy - sin(angle) * radius * dist
                    context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                                 with: .color(color.opacity(0.7)))
                    context.draw(Text(label).font(.system(size: 7, weight: .semibold)).foregroundStyle(color),
                                 at: CGPoint(x: x, y: y - 10))
                }

                // Plot a simplified colour balance indicator using histogram averages
                guard !redData.isEmpty, !greenData.isEmpty, !blueData.isEmpty else { return }
                let rAvg = weightedAverage(redData)
                let gAvg = weightedAverage(greenData)
                let bAvg = weightedAverage(blueData)
                let total = rAvg + gAvg + bAvg
                guard total > 0 else { return }
                let rN = rAvg / total
                let gN = gAvg / total
                let bN = bAvg / total

                // Map to Cb/Cr analog: Cb ∝ B-Y, Cr ∝ R-Y (Y = luminance ≈ 0.21R+0.72G+0.07B)
                let luma = 0.21 * rN + 0.72 * gN + 0.07 * bN
                let cr = CGFloat((rN - luma) * 2.5)
                let cb = CGFloat((bN - luma) * 2.5)

                let dotX = cx + cr * radius
                let dotY = cy - cb * radius  // Y-axis inverted
                let dotRect = CGRect(x: dotX - 5, y: dotY - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.9)))
            }

            Text("VEC")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 4).padding(.bottom, 2)
        }
        .frame(width: 100, height: 100)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }

    private func weightedAverage(_ bins: [Float]) -> Float {
        guard !bins.isEmpty else { return 0 }
        var sum: Float = 0
        var weight: Float = 0
        for (i, v) in bins.enumerated() {
            let pos = Float(i) / Float(bins.count)
            sum += pos * v
            weight += v
        }
        return weight > 0 ? sum / weight : 0.5
    }
}
