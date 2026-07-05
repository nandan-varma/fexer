import SwiftUI
import CoreMotion

private let sharedMotionManager: CMMotionManager = {
    let manager = CMMotionManager()
    manager.deviceMotionUpdateInterval = 1.0 / 15.0
    return manager
}()

struct LevelIndicatorView: View {
    @State private var smoothedRoll: Double = 0

    // EMA alpha: lower = smoother, higher = more responsive
    private let alpha: Double = 0.18
    // Snap to center and show green within this angle
    private let snapThreshold: Double = 1.5 * Double.pi / 180

    private var displayRoll: Double {
        abs(smoothedRoll) < snapThreshold ? 0 : smoothedRoll
    }

    private var isLevel: Bool {
        abs(smoothedRoll) < snapThreshold
    }

    var body: some View {
        ZStack {
            // Static center reference tick
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 2, height: 14)

            // Rotating horizon bar
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor)
                .frame(width: 64, height: 2)
                .rotationEffect(.radians(displayRoll))

            // Center dot
            Circle()
                .fill(barColor)
                .frame(width: 6, height: 6)
        }
        .frame(width: 88, height: 28)
        .animation(.easeInOut(duration: 0.18), value: isLevel)
        .onAppear(perform: startMotion)
        .onDisappear(perform: stopMotion)
    }

    private var barColor: Color {
        if isLevel { return .green }
        let deg = abs(smoothedRoll) * 180 / .pi
        return deg < 8 ? .white.opacity(0.9) : .white.opacity(0.6)
    }

    private func startMotion() {
        guard sharedMotionManager.isDeviceMotionAvailable else { return }
        sharedMotionManager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let m = motion else { return }
            // Derive roll from gravity vector — stable in portrait, no gimbal lock
            let g = m.gravity
            let raw = atan2(g.x, -g.y)
            smoothedRoll += alpha * (raw - smoothedRoll)
        }
    }

    private func stopMotion() {
        sharedMotionManager.stopDeviceMotionUpdates()
    }
}

#Preview {
    LevelIndicatorView()
        .padding()
        .background(.black)
}
