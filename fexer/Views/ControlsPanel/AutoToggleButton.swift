import SwiftUI

struct AutoToggleButton: View {
    @Binding var isAuto: Bool

    var body: some View {
        Button {
            isAuto.toggle()
            HapticManager.selectionChanged()
        } label: {
            Text(isAuto ? "A" : "M")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isAuto ? .black : .white)
                .frame(width: 22, height: 22)
                .background(isAuto ? Color.yellow : Color.white.opacity(0.2), in: Circle())
        }
    }
}
