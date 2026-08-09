import SwiftUI

/// Draggable thumb for the horizontal intensity sliders (style picker + adjustments row).
/// Expands and turns yellow while dragging.
struct SliderThumb: View {
    let pos: CGFloat
    let isDragging: Bool

    var body: some View {
        Circle()
            .fill(isDragging ? Color.yellow : .white)
            .frame(width: isDragging ? 9 : 6, height: isDragging ? 9 : 6)
            .offset(x: pos - (isDragging ? 4.5 : 3))
            .animation(.easeInOut(duration: 0.12), value: isDragging)
    }
}
