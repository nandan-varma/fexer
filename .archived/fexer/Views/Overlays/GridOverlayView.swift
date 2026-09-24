import SwiftUI

struct GridOverlayView: View {
    let gridType: GridType

    var body: some View {
        GeometryReader { _ in
            switch gridType {
            case .none:
                EmptyView()
            case .thirds:
                thirdsGrid()
            case .phi:
                phiGrid()
            case .square:
                squareGrid()
            case .diagonal:
                diagonalGrid()
            }
        }
        .allowsHitTesting(false)
    }

    /// Strokes vertical segments (`at` = x, spanned from/to y) and horizontal segments
    /// (`at` = y, spanned from/to x) with the shared grid style.
    private func strokeGrid(context: GraphicsContext, color: Color,
                            verticals: [(at: CGFloat, from: CGFloat, to: CGFloat)],
                            horizontals: [(at: CGFloat, from: CGFloat, to: CGFloat)]) {
        var path = Path()
        for v in verticals {
            path.move(to: CGPoint(x: v.at, y: v.from))
            path.addLine(to: CGPoint(x: v.at, y: v.to))
        }
        for h in horizontals {
            path.move(to: CGPoint(x: h.from, y: h.at))
            path.addLine(to: CGPoint(x: h.to, y: h.at))
        }
        context.stroke(path, with: .color(color), lineWidth: 0.5)
    }

    private func gridLines(count: Int, width: CGFloat, height: CGFloat)
        -> (verticals: [(at: CGFloat, from: CGFloat, to: CGFloat)],
            horizontals: [(at: CGFloat, from: CGFloat, to: CGFloat)]) {
        let verticals: [(at: CGFloat, from: CGFloat, to: CGFloat)] = (1...count).map {
            (at: width * CGFloat($0) / CGFloat(count + 1), from: 0, to: height)
        }
        let horizontals: [(at: CGFloat, from: CGFloat, to: CGFloat)] = (1...count).map {
            (at: height * CGFloat($0) / CGFloat(count + 1), from: 0, to: width)
        }
        return (verticals, horizontals)
    }

    private func thirdsGrid() -> some View {
        Canvas { context, size in
            let lines = gridLines(count: 2, width: size.width, height: size.height)
            strokeGrid(context: context, color: .white.opacity(0.35),
                       verticals: lines.verticals, horizontals: lines.horizontals)
        }
    }

    private func phiGrid() -> some View {
        Canvas { context, size in
            let phi: CGFloat = 1.61803398875
            let x1 = size.width / (phi + 1)
            let x2 = size.width - x1
            let y1 = size.height / (phi + 1)
            let y2 = size.height - y1
            strokeGrid(context: context, color: .white.opacity(0.35),
                       verticals: [(at: x1, from: 0, to: size.height), (at: x2, from: 0, to: size.height)],
                       horizontals: [(at: y1, from: 0, to: size.width), (at: y2, from: 0, to: size.width)])
        }
    }

    private func squareGrid() -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            let side = min(size.width, size.height)
            let ox = (size.width - side) / 2
            let oy = (size.height - side) / 2
            context.stroke(Path(CGRect(x: ox, y: oy, width: side, height: side)),
                           with: .color(color), lineWidth: 0.5)
            let lines = gridLines(count: 2, width: side, height: side)
            strokeGrid(context: context, color: color,
                       verticals: lines.verticals.map { (at: $0.at + ox, from: oy, to: oy + side) },
                       horizontals: lines.horizontals.map { (at: $0.at + oy, from: ox, to: ox + side) })
        }
    }

    private func diagonalGrid() -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            var path = Path()
            path.move(to: .zero);                                  path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.move(to: CGPoint(x: size.width, y: 0));          path.addLine(to: CGPoint(x: 0, y: size.height))
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }
}
