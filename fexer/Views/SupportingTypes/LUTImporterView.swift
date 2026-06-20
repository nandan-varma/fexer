import SwiftUI
import UniformTypeIdentifiers

struct LUTImporterView: UIViewControllerRepresentable {
    @Binding var bookmark: Data?
    var onImported: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: LUTImporterView

        init(parent: LUTImporterView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first, url.pathExtension.lowercased() == "cube" else {
                parent.dismiss()
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                parent.dismiss()
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? url.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
                parent.dismiss()
                return
            }
            DispatchQueue.main.async {
                self.parent.bookmark = data
                self.parent.onImported()
                self.parent.dismiss()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
