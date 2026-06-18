import SwiftUI

struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            drawChannel(context: context, size: size, values: data.luma,  color: .white.opacity(0.4))
            drawChannel(context: context, size: size, values: data.red,   color: .red.opacity(0.55))
            drawChannel(context: context, size: size, values: data.green, color: .green.opacity(0.55))
            drawChannel(context: context, size: size, values: data.blue,  color: .blue.opacity(0.55))
        }
        .frame(width: 120, height: 60)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func drawChannel(context: GraphicsContext, size: CGSize, values: [Float], color: Color) {
        guard !values.isEmpty else { return }
        let count = values.count
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) / CGFloat(count - 1) * size.width
            let y = size.height - CGFloat(v) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

#Preview {
    let values = (0..<256).map { Float($0) / 255.0 * Float.random(in: 0.5...1.0) }
    return HistogramView(data: HistogramData(red: values, green: Array(values.reversed()), blue: values, luma: values))
        .padding()
        .background(.black)
}
