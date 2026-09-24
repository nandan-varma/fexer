import Testing
@testable import Fexer

struct ColorMathTests {
    @Test func curveInterpolatesLinearlyBetweenControlPoints() {
        let identity: [Double] = [0, 0.25, 0.5, 0.75, 1]
        #expect(ColorMath.curve(identity, at: 0) == 0)
        #expect(abs(ColorMath.curve(identity, at: 0.5) - 0.5) < 0.0001)
        #expect(ColorMath.curve(identity, at: 1) == 1)
        #expect(abs(ColorMath.curve(identity, at: 0.125) - 0.125) < 0.0001)
    }

    @Test func curveWithWrongCountReturnsInputUnchanged() {
        #expect(ColorMath.curve([0, 1], at: 0.4) == 0.4)
    }

    @Test func hslRoundTripsRGB() {
        let samples: [(Double, Double, Double)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0.2, 0.6, 0.9), (0.5, 0.5, 0.5)]
        for (r, g, b) in samples {
            let (h, s, l) = ColorMath.rgbToHSL(r, g, b)
            let (r2, g2, b2) = ColorMath.hslToRGB(h, s, l)
            #expect(abs(r - r2) < 0.001)
            #expect(abs(g - g2) < 0.001)
            #expect(abs(b - b2) < 0.001)
        }
    }

    @Test func grayscaleHasZeroSaturation() {
        let (_, saturation, lightness) = ColorMath.rgbToHSL(0.4, 0.4, 0.4)
        #expect(saturation == 0)
        #expect(abs(lightness - 0.4) < 0.0001)
    }

    @Test func adjustmentCubeIsNilWhenRecipeUntouched() {
        #expect(ColorMath.adjustmentCube(EditRecipe()) == nil)
    }

    @Test func adjustmentCubeIsProducedWhenColorsAdjusted() {
        var recipe = EditRecipe()
        recipe.colors[0].saturation = 0.5
        let cube = ColorMath.adjustmentCube(recipe)
        #expect(cube != nil)
        #expect(cube?.isValid == true)
    }
}
