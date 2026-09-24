import SwiftUI

enum Theme {
    static let background = Color(red: 0.045, green: 0.048, blue: 0.047)
    static let surface = Color(red: 0.10, green: 0.11, blue: 0.105)
    static let accent = Color(red: 0.94, green: 0.76, blue: 0.38)
    static let muted = Color(red: 0.66, green: 0.69, blue: 0.66)
}

struct IconButton: View {
    let label: String
    let symbol: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44) }
            .tint(selected ? Theme.accent : .white)
            .accessibilityLabel(label)
    }
}

struct IssueAlert: ViewModifier {
    @Binding var issue: AppIssue?
    func body(content: Content) -> some View {
        content.alert(issue?.title ?? "Something went wrong", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK", role: .cancel) { issue = nil }
        } message: { Text(issue?.message ?? "Please try again.") }
    }
}
extension View {
    func issueAlert(_ issue: Binding<AppIssue?>) -> some View { modifier(IssueAlert(issue: issue)) }
}
