import Testing
@testable import Fexer

struct EditHistoryTests {
    @Test func recordingNoChangeIsIgnored() {
        var history = EditHistory()
        let recipe = EditRecipe()
        history.record(recipe, replacing: recipe)
        #expect(history.past.isEmpty)
    }

    @Test func undoReturnsPreviousAndRedoReturnsForward() {
        var history = EditHistory()
        var recipe = EditRecipe()
        let original = recipe
        recipe.exposure = 1
        history.record(original, replacing: recipe)
        let undone = history.undo(recipe)
        #expect(undone == original)
        let redone = history.redo(undone)
        #expect(redone == recipe)
    }

    @Test func newEditAfterUndoClearsRedoStack() {
        var history = EditHistory()
        var recipe = EditRecipe()
        history.record(recipe, replacing: { recipe.exposure = 1; return recipe }())
        let undone = history.undo(recipe)
        var branched = undone
        branched.contrast = 0.2
        history.record(undone, replacing: branched)
        #expect(history.future.isEmpty)
    }

    @Test func undoWithNoHistoryReturnsCurrent() {
        var history = EditHistory()
        let recipe = EditRecipe()
        #expect(history.undo(recipe) == recipe)
    }

    @Test func historyIsBoundedTo50Entries() {
        var history = EditHistory()
        var recipe = EditRecipe()
        for step in 1...60 {
            let previous = recipe
            recipe.exposure = Double(step) * 0.01
            history.record(previous, replacing: recipe)
        }
        #expect(history.past.count == 50)
    }
}
