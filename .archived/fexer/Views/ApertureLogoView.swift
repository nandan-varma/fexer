import SwiftUI

/// Camera aperture iris drawn programmatically from the same proportions as the app icon.
/// `openFraction` drives the iris animation: 0 = fully closed (opaque center), 1 = fully open.
/// Scales to any size via GeometryReader.
struct ApertureLogoView: View {
    var openFraction: Double = 1.0

    private var bladeGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.06), location: 0),
                .init(color: Color(white: 0.88).opacity(0.88), location: 0.28),
                .init(color: Color(white: 0.73).opacity(0.72), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        GeometryReader { geo in
            let sz = min(geo.size.width, geo.size.height)
            let s  = sz / 1024   // scale relative to the 1024pt icon reference frame

            ZStack {
                RadialGradient(
                    colors: [Color(white: 0.11), Color(white: 0.04)],
                    center: .center,
                    startRadius: 0,
                    endRadius: sz * 0.52
                )

                // 6 aperture blades
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 55 * s, style: .continuous)
                        .fill(bladeGradient)
                        .frame(width: 170 * s, height: 390 * s)
                        .offset(y: -285 * s)
                        .rotationEffect(.degrees(Double(i) * 60))
                }

                // Iris mask that shrinks as the aperture opens.
                // openFraction=0 → circle fills the whole view (iris "closed")
                // openFraction=1 → circle shrinks to the aperture-hole radius
                let closedR = sz * 0.52
                let openR   = 132.0 * s
                let maskR   = closedR + (openR - closedR) * openFraction

                Circle()
                    .fill(Color(white: 0.04))
                    .frame(width: maskR * 2, height: maskR * 2)

                // Details that emerge as the aperture opens
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1.5 * s)
                    .frame(width: 132 * s * 2, height: 132 * s * 2)
                    .opacity(openFraction)

                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1.5 * s)
                    .frame(width: 52 * s * 2, height: 52 * s * 2)
                    .opacity(openFraction)

                Circle()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: 10 * s * 2, height: 10 * s * 2)
                    .opacity(openFraction)
            }
            .frame(width: sz, height: sz)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
