import SwiftUI

struct SplashView: View {
    let onFinished: () -> Void

    @State private var openFraction: Double = 0
    @State private var wordmarkOpacity: Double = 0
    @State private var exitOpacity: Double = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 36) {
                ApertureLogoView(openFraction: openFraction)
                    .frame(width: 220, height: 220)

                Text("fexer")
                    .font(.system(size: 36, weight: .light))
                    .tracking(16)
                    .foregroundStyle(.white)
                    .opacity(wordmarkOpacity)
            }
        }
        .opacity(exitOpacity)
        .onAppear(perform: runAnimation)
    }

    private func runAnimation() {
        // 1. Iris opens with a spring
        withAnimation(.spring(response: 0.75, dampingFraction: 0.68).delay(0.1)) {
            openFraction = 1.0
        }
        // 2. Wordmark fades in
        withAnimation(.easeIn(duration: 0.45).delay(0.55)) {
            wordmarkOpacity = 1
        }
        // 3. Whole view fades out
        withAnimation(.easeInOut(duration: 0.38).delay(1.9)) {
            exitOpacity = 0
        }
        // 4. Notify parent
        Task {
            try? await Task.sleep(for: .milliseconds(2300))
            await MainActor.run { onFinished() }
        }
    }
}
