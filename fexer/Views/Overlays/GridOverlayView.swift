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

    private func thirdsGrid() -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0));            path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y));            path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }

    private func phiGrid() -> some View {
        Canvas { context, size in
            let phi: CGFloat = 1.61803398875
            let color = Color.white.opacity(0.35)
            let x1 = size.width / (phi + 1)
            let x2 = size.width - x1
            let y1 = size.height / (phi + 1)
            let y2 = size.height - y1
            var path = Path()
            for x in [x1, x2] {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in [y1, y2] {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }

    private func squareGrid() -> some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.35)
            let side = min(size.width, size.height)
            let ox = (size.width - side) / 2
            let oy = (size.height - side) / 2
            var path = Path(CGRect(x: ox, y: oy, width: side, height: side))
            for i in 1...2 {
                let x = ox + side * CGFloat(i) / 3
                let y = oy + side * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: oy));       path.addLine(to: CGPoint(x: x, y: oy + side))
                path.move(to: CGPoint(x: ox, y: y));       path.addLine(to: CGPoint(x: ox + side, y: y))
            }
            context.stroke(path, with: .color(color), lineWidth: 0.5)
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
