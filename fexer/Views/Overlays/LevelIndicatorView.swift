import SwiftUI
import CoreMotion

private let sharedMotionManager: CMMotionManager = {
    let manager = CMMotionManager()
    manager.deviceMotionUpdateInterval = 1.0 / 30.0
    return manager
}()

struct LevelIndicatorView: View {
    @State private var roll: Double = 0

    var body: some View {
        ZStack {
            // Center reference mark
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.3))
                .frame(width: 4, height: 12)

            // Horizon line
            RoundedRectangle(cornerRadius: 1)
                .fill(levelColor)
                .frame(width: 80, height: 2)
                .rotationEffect(.radians(roll))

            // Center dot
            Circle()
                .fill(levelColor)
                .frame(width: 6, height: 6)
        }
        .frame(width: 100, height: 24)
        .onAppear(perform: startMotion)
        .onDisappear(perform: stopMotion)
    }

    private var levelColor: Color {
        let degrees = abs(roll * 180 / .pi)
        if degrees < 1 { return .green }
        if degrees < 3 { return .yellow }
        return .red
    }

    private func startMotion() {
        guard sharedMotionManager.isDeviceMotionAvailable else { return }
        sharedMotionManager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let m = motion else { return }
            roll = m.attitude.roll
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
