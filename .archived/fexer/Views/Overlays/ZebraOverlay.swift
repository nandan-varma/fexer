import SwiftUI

/// Transparent pass-through overlay — zebra stripes are rendered directly into the CI pipeline.
struct ZebraOverlay: View {
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
    }
}
