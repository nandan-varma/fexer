import SwiftUI

struct GridOverlayView: View {
    let gridType: GridType

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            switch gridType {
            case .none:
                EmptyView()
            case .thirds:
                thirdsGrid(width: w, height: h)
            case .phi:
                phiGrid(width: w, height: h)
            case .square:
                squareGrid(width: w, height: h)
            case .diagonal:
                diagonalGrid(width: w, height: h)
            }
        }
        .allowsHitTesting(false)
    }

    private func thirdsGrid(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                var vLine = Path(); vLine.move(to: CGPoint(x: x, y: 0)); vLine.addLine(to: CGPoint(x: x, y: size.height))
                var hLine = Path(); hLine.move(to: CGPoint(x: 0, y: y)); hLine.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(vLine, with: .color(color), lineWidth: 0.5)
                context.stroke(hLine, with: .color(color), lineWidth: 0.5)
            }
        }
    }

    private func phiGrid(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let phi: CGFloat = 1.61803398875
            let color = Color.white.opacity(0.35)
            let x1 = size.width / (phi + 1)
            let x2 = size.width - x1
            let y1 = size.height / (phi + 1)
            let y2 = size.height - y1
            for x in [x1, x2] {
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(color), lineWidth: 0.5)
            }
            for y in [y1, y2] {
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(color), lineWidth: 0.5)
            }
        }
    }

    private func squareGrid(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            let side = min(size.width, size.height)
            let ox = (size.width - side) / 2
            let oy = (size.height - side) / 2
            let rect = CGRect(x: ox, y: oy, width: side, height: side)
            context.stroke(Path(rect), with: .color(color), lineWidth: 0.5)
            for i in 1...2 {
                let x = ox + side * CGFloat(i) / 3
                let y = oy + side * CGFloat(i) / 3
                var vLine = Path(); vLine.move(to: CGPoint(x: x, y: oy)); vLine.addLine(to: CGPoint(x: x, y: oy + side))
                var hLine = Path(); hLine.move(to: CGPoint(x: ox, y: y)); hLine.addLine(to: CGPoint(x: ox + side, y: y))
                context.stroke(vLine, with: .color(color), lineWidth: 0.5)
                context.stroke(hLine, with: .color(color), lineWidth: 0.5)
            }
        }
    }

    private func diagonalGrid(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            var d1 = Path(); d1.move(to: .zero); d1.addLine(to: CGPoint(x: size.width, y: size.height))
            var d2 = Path(); d2.move(to: CGPoint(x: size.width, y: 0)); d2.addLine(to: CGPoint(x: 0, y: size.height))
            context.stroke(d1, with: .color(color), lineWidth: 0.5)
            context.stroke(d2, with: .color(color), lineWidth: 0.5)
        }
    }
}
