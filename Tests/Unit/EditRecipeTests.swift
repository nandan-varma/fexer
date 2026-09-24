import Testing
import Foundation
@testable import Fexer

struct EditRecipeTests {
    @Test func defaultRecipeIsNotModified() {
        #expect(!EditRecipe().isModified)
    }

    @Test func changingAnyFieldMarksModified() {
        var recipe = EditRecipe()
        recipe.exposure = 0.5
        #expect(recipe.isModified)
    }

    @Test func validatedClampsOutOfRangeAdjustments() {
        var recipe = EditRecipe()
        recipe.exposure = 99
        recipe.contrast = -99
        recipe.vignette = 5
        let validated = recipe.validated
        #expect(validated.exposure == Adjustment.exposure.range.upperBound)
        #expect(validated.contrast == Adjustment.contrast.range.lowerBound)
        #expect(validated.vignette == Adjustment.vignette.range.upperBound)
    }

    @Test func validatedClampsCropAndIntensity() {
        var recipe = EditRecipe()
        recipe.intensity = 5
        recipe.cropZoom = 0
        recipe.cropX = -1
        recipe.cropY = 2
        let validated = recipe.validated
        #expect(validated.intensity == 1)
        #expect(validated.cropZoom == 1)
        #expect(validated.cropX == 0)
        #expect(validated.cropY == 1)
    }

    @Test func validatedNormalizesQuarterTurns() {
        var recipe = EditRecipe()
        recipe.quarterTurns = -1
        #expect(recipe.validated.quarterTurns == 3)
        recipe.quarterTurns = 6
        #expect(recipe.validated.quarterTurns == 2)
    }

    @Test func validatedPadsAndClampsColorsAndCurves() {
        var recipe = EditRecipe()
        recipe.colors = [ColorBand(hue: 200, saturation: -5, luminance: 5)]
        recipe.curves = [[2, -1, 0.5, 0.75, 1]]
        let validated = recipe.validated
        #expect(validated.colors.count == 8)
        #expect(validated.colors[0].hue == 60)
        #expect(validated.colors[0].saturation == -1)
        #expect(validated.colors[1] == ColorBand())
        #expect(validated.curves.count == 4)
        #expect(validated.curves[0][0] == 1)
        #expect(validated.curves[0][1] == 0)
        #expect(validated.curves[1] == [0, 0.25, 0.5, 0.75, 1])
    }

    @Test func recipeRoundTripsThroughJSON() throws {
        var recipe = EditRecipe()
        recipe.styleID = "portra"
        recipe.exposure = 0.3
        recipe.colors[2].hue = 10
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
    }
}
