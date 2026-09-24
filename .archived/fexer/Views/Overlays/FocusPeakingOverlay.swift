import SwiftUI

/// Transparent pass-through overlay — focus peaking is rendered directly into the CI pipeline.
/// This view exists as a named anchor for the ZStack layer order.
struct FocusPeakingOverlay: View {
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
    }
}
