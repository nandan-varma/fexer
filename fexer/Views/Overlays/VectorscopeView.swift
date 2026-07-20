import SwiftUI

/// Vectorscope — per-pixel Cb/Cr (Rec.601) density heatmap.
/// Horizontal axis = Cb (B-Y):  left = -0.5 (blue/cyan), right = +0.5 (red/yellow)
/// Vertical axis   = Cr (R-Y):  top  = +0.5 (red/magenta), bottom = -0.5 (cyan/green)
/// Color targets shown at 75% saturation, matching broadcast standard bar positions.
struct VectorscopeView: View {
    var data = VectorscopeData()

    var body: some View {
        ZStack {
            Canvas { context, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let radius = min(cx, cy) - 4

                // Background circle
                context.fill(
                    Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(.black.opacity(0.4))
                )

                // Outer ring
                let ring = Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius,
                                                   width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(.white.opacity(0.2)), lineWidth: 0.5)

                // 75% saturation ring (inner reference circle)
                let ring75 = Path(ellipseIn: CGRect(x: cx - radius * 0.75, y: cy - radius * 0.75,
                                                     width: radius * 1.5, height: radius * 1.5))
                context.stroke(ring75, with: .color(.white.opacity(0.08)), lineWidth: 0.5)

                // Crosshairs
                var hLine = Path()
                hLine.move(to: CGPoint(x: cx - radius, y: cy))
                hLine.addLine(to: CGPoint(x: cx + radius, y: cy))
                context.stroke(hLine, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

                var vLine = Path()
                vLine.move(to: CGPoint(x: cx, y: cy - radius))
                vLine.addLine(to: CGPoint(x: cx, y: cy + radius))
                context.stroke(vLine, with: .color(.white.opacity(0.12)), lineWidth: 0.5)

                // Density heatmap — render each cell within the circle
                if !data.isEmpty {
                    let gridSize = VectorscopeData.size
                    let cellW = radius * 2 / CGFloat(gridSize)
                    let cellH = radius * 2 / CGFloat(gridSize)
                    let startX = cx - radius
                    let startY = cy - radius

                    for row in 0..<gridSize {
                        for col in 0..<gridSize {
                            let density = data[row, col]
                            guard density > 0.02 else { continue }

                            // Normalized position: 0…1 within the diameter
                            let cbNorm = (CGFloat(col) / CGFloat(gridSize - 1)) - 0.5  // -0.5 … +0.5
                            let crNorm = 0.5 - (CGFloat(row) / CGFloat(gridSize - 1))  // +0.5 … -0.5

                            // Skip pixels outside the unit circle
                            let dist = sqrt(cbNorm * cbNorm + crNorm * crNorm)
                            guard dist <= 0.52 else { continue }

                            let px = startX + CGFloat(col) * cellW
                            let py = startY + CGFloat(row) * cellH

                            var cell = Path()
                            cell.addRect(CGRect(x: px, y: py, width: max(1, cellW), height: max(1, cellH)))
                            // Hue from Cb/Cr angle, brightened by density
                            let angle = atan2(Double(crNorm), Double(cbNorm))
                            let hue = (angle / (.pi * 2) + 1).truncatingRemainder(dividingBy: 1)
                            context.fill(cell, with: .color(
                                Color(hue: hue, saturation: 0.7, brightness: 0.95)
                                    .opacity(Double(density) * 0.9 + 0.05)
                            ))
                        }
                    }
                }

                // Color target boxes at standard 75% saturation positions
                // Angles in the Cb-Cr plane (Cb = X, Cr = Y, standard colorimetry)
                let targets: [(String, Double, Color)] = [
                    ("R", 103.0, .red),
                    ("Mg", 61.0, .purple),
                    ("B", -17.0, .blue),
                    ("Cy", -77.0, .cyan),
                    ("G", -137.0, .green),
                    ("Yw", 163.0, .yellow)
                ]
                for (label, angleDeg, color) in targets {
                    let angle = angleDeg * .pi / 180
                    let dist: CGFloat = 0.75
                    let x = cx + CGFloat(cos(angle)) * radius * dist
                    let y = cy - CGFloat(sin(angle)) * radius * dist
                    let boxSize: CGFloat = 6
                    var box = Path()
                    box.addRect(CGRect(x: x - boxSize / 2, y: y - boxSize / 2,
                                       width: boxSize, height: boxSize))
                    context.stroke(box, with: .color(color.opacity(0.85)), lineWidth: 1)
                    context.draw(
                        Text(label).font(.system(size: 6.5, weight: .bold)).foregroundStyle(color),
                        at: CGPoint(x: x, y: y - 8)
                    )
                }

                // Skin tone line (from origin at ~123° in standard Cb-Cr)
                let skinAngle = 123.0 * Double.pi / 180.0
                var skinLine = Path()
                skinLine.move(to: CGPoint(x: cx, y: cy))
                skinLine.addLine(to: CGPoint(
                    x: cx + CGFloat(cos(skinAngle)) * radius,
                    y: cy - CGFloat(sin(skinAngle)) * radius
                ))
                context.stroke(skinLine, with: .color(.orange.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
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
}
