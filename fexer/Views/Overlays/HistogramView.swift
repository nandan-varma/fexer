import SwiftUI

enum HistogramMode: String, CaseIterable {
    case rgbl = "RGBL"
    case luma = "Luma"
    case parade = "RGB"
}

struct HistogramView: View {
    let data: HistogramData
    @AppStorage("histogramMode") private var mode: HistogramMode = .rgbl

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Canvas { context, size in
                switch mode {
                case .rgbl:
                    drawChannel(context: context, size: size, values: data.luma,  color: .white.opacity(0.4))
                    drawChannel(context: context, size: size, values: data.red,   color: .red.opacity(0.55))
                    drawChannel(context: context, size: size, values: data.green, color: .green.opacity(0.55))
                    drawChannel(context: context, size: size, values: data.blue,  color: .blue.opacity(0.55))
                case .luma:
                    drawChannel(context: context, size: size, values: data.luma, color: .white.opacity(0.8))
                case .parade:
                    let colW = size.width / 3
                    drawChannel(context: context, size: size, values: data.red,
                                color: .red.opacity(0.75),
                                xOffset: 0, xScale: colW / size.width)
                    drawChannel(context: context, size: size, values: data.green,
                                color: .green.opacity(0.75),
                                xOffset: colW, xScale: colW / size.width)
                    drawChannel(context: context, size: size, values: data.blue,
                                color: .blue.opacity(0.75),
                                xOffset: colW * 2, xScale: colW / size.width)
                }
            }

            Text(mode.rawValue)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.yellow)
                .tracking(2)
                .padding(.trailing, 4)
                .padding(.bottom, 3)
        }
        .frame(width: 120, height: 60)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .onTapGesture {
            let all = HistogramMode.allCases
            guard let idx = all.firstIndex(of: mode) else { return }
            mode = all[(idx + 1) % all.count]
            HapticManager.light()
        }
    }

    private func drawChannel(
        context: GraphicsContext,
        size: CGSize,
        values: [Float],
        color: Color,
        xOffset: CGFloat = 0,
        xScale: CGFloat = 1
    ) {
        guard !values.isEmpty else { return }
        let count = values.count
        var path = Path()
        path.move(to: CGPoint(x: xOffset, y: size.height))
        for (i, v) in values.enumerated() {
            let x = xOffset + CGFloat(i) / CGFloat(count - 1) * size.width * xScale
            let y = size.height - CGFloat(v) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: xOffset + size.width * xScale, y: size.height))
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
