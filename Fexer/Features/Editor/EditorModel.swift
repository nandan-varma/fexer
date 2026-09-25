import Foundation
import Observation
import UIKit

@MainActor @Observable
final class EditorModel {
    var recipe: EditRecipe
    private(set) var image: UIImage?
    private(set) var originalImage: UIImage?
    private(set) var source: Data?
    private(set) var rendering = false
    private(set) var saving = false
    var issue: AppIssue?
    var history = EditHistory()
    private var gestureStart: EditRecipe?
    private var renderTask: Task<Void, Never>?
    let item: LibraryItem
    let library: LibraryModel
    init(item: LibraryItem, library: LibraryModel) { self.item = item; self.library = library; recipe = item.recipe.validated }
    func load() async {
        do {
            let data = try await Diagnostics.time("editor.loadSource") { try await library.store.source(for: item) }
            source = data
            originalImage = try await UIImage(cgImage: Diagnostics.time("editor.loadOriginalPreview") { try await library.renderer.preview(data: data, edit: EditRecipe()) })
            render()
        } catch { fail(error) }
    }
    func render() {
        renderTask?.cancel()
        guard let source else { return }
        let edit = recipe
        rendering = true
        renderTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(80))
                let pixels = try await library.renderer.preview(data: source, edit: edit)
                try Task.checkCancellation()
                image = UIImage(cgImage: pixels)
                rendering = false
            } catch is CancellationError {} catch { rendering = false; fail(error) }
        }
    }
    func change(_ change: (inout EditRecipe) -> Void) {
        let previous = recipe
        change(&recipe)
        recipe = recipe.validated
        history.record(previous, replacing: recipe)
    }
    func gesture(_ started: Bool) {
        if started { gestureStart = recipe }
        else if let previous = gestureStart { history.record(previous, replacing: recipe); gestureStart = nil }
    }
    func undo() { recipe = history.undo(recipe) }
    func redo() { recipe = history.redo(recipe) }
    func save() async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do { _ = try await Diagnostics.time("editor.saveEdits") { try await library.saveEdits(recipe, for: item) }; return true }
        catch { fail(error); return false }
    }
    func importCube(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let cube = try await library.renderer.loadCube(from: url)
            change { $0.importedCube = cube }
        } catch { issue = AppIssue("Couldn’t import LUT", "Choose a valid .cube file with a 3D size from 2 to 64 and a standard 0–1 domain.") }
    }
    private func fail(_ error: any Error) {
        Diagnostics.report(error, operation: "Edit photo")
        issue = error as? AppIssue ?? AppIssue("Couldn’t edit this photo", "The original is safe. Please try again.")
    }
}
