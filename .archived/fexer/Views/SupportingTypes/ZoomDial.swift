import SwiftUI

struct ZoomDial: View {
    let factors: [CGFloat]
    let currentZoom: CGFloat
    let onZoom: (CGFloat) -> Void
    let onDismiss: () -> Void

    private let arcRadius: CGFloat = 100
    private let arcStartDeg: Double = 215
    private let arcEndDeg: Double = 325

    private var minZoom: CGFloat { factors.first ?? 0.5 }
    private var maxZoom: CGFloat { factors.last ?? 10 }

    private func zoomFraction(_ zoom: CGFloat) -> Double {
        let logMin = log(Double(max(minZoom, 0.01)))
        let logMax = log(Double(max(maxZoom, 0.01)))
        let logZ = log(Double(max(zoom, 0.01))).fxClamped(to: logMin...logMax)
        return (logZ - logMin) / (logMax - logMin)
    }

    private func zoomFromFraction(_ t: Double) -> CGFloat {
        let logMin = log(Double(max(minZoom, 0.01)))
        let logMax = log(Double(max(maxZoom, 0.01)))
        return CGFloat(exp(logMin + t.fxClamped(to: 0...1) * (logMax - logMin)))
    }

    private func zoomToAngleDeg(_ zoom: CGFloat) -> Double {
        arcStartDeg + zoomFraction(zoom) * (arcEndDeg - arcStartDeg)
    }

    private func arcPoint(deg: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let rad = deg * .pi / 180
        return CGPoint(x: center.x + radius * cos(rad), y: center.y + radius * sin(rad))
    }

    var body: some View {
        let w: CGFloat = arcRadius * 2 + 60
        let h: CGFloat = arcRadius + 22

        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height)
            let steps = 80

            // Track arc
            var track = Path()
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let pt = arcPoint(deg: arcStartDeg + t * (arcEndDeg - arcStartDeg),
                                  center: center, radius: arcRadius)
                if i == 0 { track.move(to: pt) } else { track.addLine(to: pt) }
            }
            context.stroke(track, with: .color(.white.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Filled arc from start up to current zoom position
            let frac = zoomFraction(currentZoom)
            let fillEndDeg = arcStartDeg + frac * (arcEndDeg - arcStartDeg)
            let fillSteps = max(1, Int(frac * Double(steps)))
            var fill = Path()
            for i in 0...fillSteps {
                let t = Double(i) / Double(fillSteps)
                let pt = arcPoint(deg: arcStartDeg + t * (fillEndDeg - arcStartDeg),
                                  center: center, radius: arcRadius)
                if i == 0 { fill.move(to: pt) } else { fill.addLine(to: pt) }
            }
            context.stroke(fill, with: .color(.yellow.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Tick marks at each optical stop
            for factor in factors {
                let deg = zoomToAngleDeg(factor)
                let inner = arcPoint(deg: deg, center: center, radius: arcRadius - 9)
                let outer = arcPoint(deg: deg, center: center, radius: arcRadius + 9)
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: outer)
                context.stroke(tick, with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            // Thumb at current zoom
            let thumbDeg = zoomToAngleDeg(currentZoom)
            let thumbPt = arcPoint(deg: thumbDeg, center: center, radius: arcRadius)
            var thumb = Path()
            thumb.addEllipse(in: CGRect(x: thumbPt.x - 9, y: thumbPt.y - 9, width: 18, height: 18))
            context.fill(thumb, with: .color(.white))
            context.stroke(thumb, with: .color(.yellow.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2))
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: w / 2, y: h)
                    let dx = value.location.x - center.x
                    let dy = value.location.y - center.y
                    var deg = atan2(dy, dx) * 180 / .pi
                    if deg < 0 { deg += 360 }

                    if deg > arcEndDeg {
                        deg = arcEndDeg
                    } else if deg < arcStartDeg {
                        let toStart = arcStartDeg - deg
                        let toEnd = 360 - arcEndDeg + deg
                        deg = toStart <= toEnd ? arcStartDeg : arcEndDeg
                    }

                    let t = (deg - arcStartDeg) / (arcEndDeg - arcStartDeg)
                    onZoom(zoomFromFraction(t))
                }
                .onEnded { _ in onDismiss() }
        )
    }
}
