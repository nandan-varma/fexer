import XCTest
import CoreImage
@testable import fexer

final class PhotoStyleTests: XCTestCase {
    func testCatalogHas21Styles() {
        XCTAssertEqual(PhotoStyle.catalog.count, 21)
    }

    func testNoneIsFirstInCustomCategory() {
        XCTAssertEqual(PhotoStyle.none.name, "None")
        XCTAssertEqual(PhotoStyle.none.category, .custom)
        XCTAssertNil(PhotoStyle.none.lutFileName)
    }

    func testAllCatalogStylesHaveNames() {
        for style in PhotoStyle.catalog {
            XCTAssertFalse(style.name.isEmpty)
            XCTAssertFalse(style.description.isEmpty)
        }
    }

    func testAllCatalogStylesHaveValidIntensity() {
        for style in PhotoStyle.catalog {
            XCTAssertTrue(style.baseIntensity > 0 && style.baseIntensity <= 1)
        }
    }

    func testStyleEqualityById() {
        let a = PhotoStyle.catalog[0]
        let b = PhotoStyle.catalog[0]
        XCTAssertEqual(a, b)
    }

    func testStylesAreUniqueById() {
        let ids = Set(PhotoStyle.catalog.map(\.id))
        XCTAssertEqual(ids.count, PhotoStyle.catalog.count)
    }
}

final class fxClampedTests: XCTestCase {
    func testClampsBelowRange() {
        XCTAssertEqual(5.0.fxClamped(to: 10...20), 10)
    }

    func testClampsAboveRange() {
        XCTAssertEqual(25.0.fxClamped(to: 10...20), 20)
    }

    func testWithinRange() {
        XCTAssertEqual(15.0.fxClamped(to: 10...20), 15)
    }

    func testExactBoundary() {
        XCTAssertEqual(10.0.fxClamped(to: 10...20), 10)
        XCTAssertEqual(20.0.fxClamped(to: 10...20), 20)
    }

    func testFloatClamping() {
        let result: Float = Float(0.5).fxClamped(to: 0...1)
        XCTAssertEqual(result, 0.5)
    }

    func testCGFloatClamping() {
        let result: CGFloat = (-5).fxClamped(to: 0...10)
        XCTAssertEqual(result, 0)
    }
}

final class StyleTransformsTests: XCTestCase {
    func testParamsForNoneStyleReturnsIdentity() {
        let none = PhotoStyle.none
        let params = StyleTransforms.params(for: none)
        // None should produce identity-like params
        XCTAssertEqual(params.saturation, 1.0)
        XCTAssertEqual(params.contrast, 1.0)
        XCTAssertEqual(params.exposure, 0.0)
    }

    func testAllCatalogStylesHaveParams() {
        for style in PhotoStyle.catalog {
            let params = StyleTransforms.params(for: style)
            // Verify params are within expected ranges
            XCTAssertTrue(params.saturation >= 0 && params.saturation <= 2)
            XCTAssertTrue(params.contrast >= 0.5 && params.contrast <= 2)
            XCTAssertTrue(params.exposure >= -2 && params.exposure <= 2)
        }
    }
}

final class CaptureSettingsTests: XCTestCase {
    func testDefaultValues() {
        let settings = CaptureSettings()
        XCTAssertTrue(settings.isAutoISO)
        XCTAssertTrue(settings.isAutoShutter)
        XCTAssertTrue(settings.isAutoWhiteBalance)
        XCTAssertTrue(settings.isAutoFocus)
        XCTAssertEqual(settings.exposureCompensation, 0)
        XCTAssertFalse(settings.isAELocked)
    }

    func testShutterSpeedDisplayString() {
        let settings = CaptureSettings()
        // 1/250 → "1/250"
        XCTAssertEqual(CaptureSettings.formatShutterSpeed(1.0 / 250.0), "1/250")
        // 1s → "1\""
        XCTAssertEqual(CaptureSettings.formatShutterSpeed(1.0), "1\"")
        // 30s → "30\""
        XCTAssertEqual(CaptureSettings.formatShutterSpeed(30.0), "30\"")
        // 1/8000 → "1/8000"
        XCTAssertEqual(CaptureSettings.formatShutterSpeed(1.0 / 8000.0), "1/8000")
    }
}

final class LUTLoaderProceduralTests: XCTestCase {
    func testProceduralGenerationProducesValidData() {
        let loader = LUTLoader.shared
        let (data, dim) = loader.generateProcedural(name: "test_identity") { r, g, b in
            (r, g, b)
        }
        XCTAssertEqual(dim, 17)
        XCTAssertEqual(data.length, 17 * 17 * 17 * 4 * MemoryLayout<Float32>.size)
        // Verify identity: first entry (r=0,g=0,b=0) should be (0,0,0,1)
        let bytes = data.bytes.bindMemory(to: Float32.self, capacity: data.length / MemoryLayout<Float32>.size)
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[2], 0)
        XCTAssertEqual(bytes[3], 1.0)
        // Last entry (r=1,g=1,b=1) should be (1,1,1,1)
        let last = (data.length / MemoryLayout<Float32>.size) - 4
        XCTAssertEqual(bytes[last], 1.0)
        XCTAssertEqual(bytes[last + 1], 1.0)
        XCTAssertEqual(bytes[last + 2], 1.0)
        XCTAssertEqual(bytes[last + 3], 1.0)
    }

    func testProceduralGenerationCachesResult() {
        let loader = LUTLoader.shared
        let (data1, _) = loader.generateProcedural(name: "test_cache_style") { r, g, b in
            (r * 0.5, g, b)
        }
        let (data2, _) = loader.generateProcedural(name: "test_cache_style") { r, g, b in
            (r * 0.5, g, b)
        }
        // Same pointer means cached
        XCTAssertEqual(data1, data2)
    }

    func testProceduralBWTransform() {
        let loader = LUTLoader.shared
        // BW transform: saturation = 0
        let p = StyleParams(saturation: 0, bwR: 0.3, bwG: 0.59, bwB: 0.11)
        let (data, dim) = loader.generateProcedural(name: "test_bw") { r, g, b in
            StyleTransforms.apply(p, r: r, g: g, b: b)
        }
        XCTAssertEqual(dim, 17)
        // Verify the first entry is luma (all channels equal)
        let bytes = data.bytes.bindMemory(to: Float32.self, capacity: data.length / MemoryLayout<Float32>.size)
        let redIdx = 0, greenIdx = 1, blueIdx = 2
        // At (0,0,0) output should be (0,0,0,1)
        XCTAssertEqual(bytes[redIdx], 0)
        XCTAssertEqual(bytes[greenIdx], 0)
        XCTAssertEqual(bytes[blueIdx], 0)
    }
}

final class HistogramCalculatorTests: XCTestCase {
    func testHistogramFromSolidImage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let hist = HistogramCalculator.compute(from: image, context: context)
        XCTAssertEqual(hist.red.count, 256)
        XCTAssertEqual(hist.green.count, 256)
        XCTAssertEqual(hist.blue.count, 256)
        XCTAssertEqual(hist.luma.count, 256)
        let peakRed = hist.red.max() ?? 0
        let peakGreen = hist.green.max() ?? 0
        let peakBlue = hist.blue.max() ?? 0
        XCTAssertGreaterThan(peakRed, 0)
        XCTAssertGreaterThan(peakGreen, 0)
        XCTAssertGreaterThan(peakBlue, 0)
    }

    func testHistogramNormalization() {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let hist = HistogramCalculator.compute(from: image, context: context)
        for v in hist.red { XCTAssertLessThanOrEqual(v, 1.0) }
        for v in hist.green { XCTAssertLessThanOrEqual(v, 1.0) }
        for v in hist.blue { XCTAssertLessThanOrEqual(v, 1.0) }
        for v in hist.luma { XCTAssertLessThanOrEqual(v, 1.0) }
    }
}

// MARK: - EditState Tests

final class EditStateTests: XCTestCase {
    func testDefaultIsNotModified() {
        XCTAssertFalse(EditState().isModified)
    }

    func testExposureFlipsModified() {
        var s = EditState(); s.exposure = 0.1
        XCTAssertTrue(s.isModified)
    }

    func testContrastFlipsModified() {
        var s = EditState(); s.contrast = 0.1
        XCTAssertTrue(s.isModified)
    }

    func testVignetteFlipsModified() {
        var s = EditState(); s.vignette = 0.5
        XCTAssertTrue(s.isModified)
    }

    func testCropRectFlipsModified() {
        var s = EditState()
        s.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(s.isModified)
    }

    func testQuarterTurnsFlipsModified() {
        var s = EditState(); s.quarterTurns = 1
        XCTAssertTrue(s.isModified)
    }

    func testDefaultHSLIsNotAdjusted() {
        XCTAssertFalse(EditState().hasHSLAdjustments)
    }

    func testHSLHueDetected() {
        var s = EditState(); s.hslRed.hue = 1
        XCTAssertTrue(s.hasHSLAdjustments)
    }

    func testHSLSaturationDetected() {
        var s = EditState(); s.hslGreen.saturation = 0.5
        XCTAssertTrue(s.hasHSLAdjustments)
    }

    func testIdentityCurveIsNotAdjusted() {
        XCTAssertFalse(EditState().hasCurveAdjustments)
    }

    func testCurveAdjustmentDetected() {
        var s = EditState()
        s.curveR[2] = SIMD2(0.5, 0.6)
        XCTAssertTrue(s.hasCurveAdjustments)
    }
}

// MARK: - CropRatio Geometry Tests

final class CropRatioGeometryTests: XCTestCase {
    func testFullWithNoImageAspectReturnsZero() {
        XCTAssertEqual(CropRatio.full.letterboxBarHeight(viewSize: CGSize(width: 390, height: 844)), 0)
    }

    func testSquareCropBarHeight() {
        let bar = CropRatio.r1_1.letterboxBarHeight(viewSize: CGSize(width: 390, height: 844))
        XCTAssertEqual(bar, (844 - 390) / 2, accuracy: 0.5)
    }

    func test16_9CropBarHeight() {
        let view = CGSize(width: 390, height: 844)
        let contentH = 390.0 / (9.0 / 16.0)
        let expected = (844 - contentH) / 2
        let bar = CropRatio.r16_9.letterboxBarHeight(viewSize: view)
        XCTAssertEqual(bar, expected, accuracy: 0.5)
    }

    func testFullWithLandscapeImageAspect() {
        let view = CGSize(width: 390, height: 844)
        let imageAspect: CGFloat = 4.0 / 3.0
        let contentH = 390.0 / imageAspect
        let expected = (844 - contentH) / 2
        let bar = CropRatio.full.letterboxBarHeight(viewSize: view, imageAspect: imageAspect)
        XCTAssertEqual(bar, expected, accuracy: 0.5)
    }

    func testPortraitAspectValues() {
        XCTAssertEqual(CropRatio.r1_1.portraitAspect, 1.0)
        XCTAssertEqual(CropRatio.r16_9.portraitAspect ?? 0, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertNil(CropRatio.full.portraitAspect)
    }
}

// MARK: - LUTLoader parseCube Tests

final class LUTLoaderParseTests: XCTestCase {
    private static let cube2x2Identity = """
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

    func testParseCubeValidDim2() {
        let result = LUTLoader.parseCube(content: Self.cube2x2Identity)
        XCTAssertNotNil(result)
        let (data, dim) = result!
        XCTAssertEqual(dim, 2)
        XCTAssertEqual(data.count, 2 * 2 * 2 * 4 * MemoryLayout<Float32>.size)
    }

    func testParseCubeIdentityCornerValues() {
        let (data, _) = LUTLoader.parseCube(content: Self.cube2x2Identity)!
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        XCTAssertEqual(floats[0], 0, accuracy: 0.001)   // first entry r
        XCTAssertEqual(floats[1], 0, accuracy: 0.001)   // first entry g
        XCTAssertEqual(floats[2], 0, accuracy: 0.001)   // first entry b
        XCTAssertEqual(floats[3], 1.0, accuracy: 0.001) // first entry a
        XCTAssertEqual(floats[floats.count - 4], 1.0, accuracy: 0.001) // last entry r
        XCTAssertEqual(floats[floats.count - 3], 1.0, accuracy: 0.001) // last entry g
        XCTAssertEqual(floats[floats.count - 2], 1.0, accuracy: 0.001) // last entry b
        XCTAssertEqual(floats[floats.count - 1], 1.0, accuracy: 0.001) // last entry a
    }

    func testParseCubeGarbageReturnsNil() {
        XCTAssertNil(LUTLoader.parseCube(content: "not a lut file"))
    }

    func testParseCubeMissingDimReturnsNil() {
        // No LUT_3D_SIZE → defaults to 33, entry count won't match 2
        XCTAssertNil(LUTLoader.parseCube(content: "0.0 0.0 0.0\n1.0 0.0 0.0"))
    }

    func testParseCubeCommentsSkipped() {
        let withComments = """
            # Title comment
            LUT_3D_SIZE 2
            # Another comment
            0.0 0.0 0.0
            1.0 0.0 0.0
            0.0 1.0 0.0
            1.0 1.0 0.0
            0.0 0.0 1.0
            1.0 0.0 1.0
            0.0 1.0 1.0
            1.0 1.0 1.0
            """
        XCTAssertNotNil(LUTLoader.parseCube(content: withComments))
    }
}

// MARK: - CapturePreset Tests

final class CapturePresetTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let preset = CapturePreset(
            name: "Golden Hour",
            isoValue: 400,
            shutterSpeedSeconds: 1.0 / 500.0,
            whiteBalanceKelvin: 5600,
            whiteBalanceTint: 5,
            exposureCompensation: -0.5,
            isAutoISO: false,
            isAutoShutter: false,
            isAutoWhiteBalance: false,
            styleName: "Portra 400"
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(CapturePreset.self, from: data)
        XCTAssertEqual(decoded.id, preset.id)
        XCTAssertEqual(decoded.name, preset.name)
        XCTAssertEqual(decoded.isoValue, preset.isoValue)
        XCTAssertEqual(decoded.styleName, preset.styleName)
        XCTAssertEqual(decoded.exposureCompensation, preset.exposureCompensation)
    }

    func testSaveAndDelete() {
        let key = "com.fexer.capturePresets"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let mgr = CapturePresetsManager()
        let p1 = CapturePreset(name: "A", isoValue: 100, shutterSpeedSeconds: 1/250, whiteBalanceKelvin: 5500, whiteBalanceTint: 0, exposureCompensation: 0, isAutoISO: true, isAutoShutter: true, isAutoWhiteBalance: true, styleName: nil)
        let p2 = CapturePreset(name: "B", isoValue: 200, shutterSpeedSeconds: 1/500, whiteBalanceKelvin: 6500, whiteBalanceTint: 5, exposureCompensation: 0.5, isAutoISO: false, isAutoShutter: false, isAutoWhiteBalance: false, styleName: "Velvia 50")

        mgr.save(p1)
        mgr.save(p2)
        XCTAssertEqual(mgr.presets.count, 2)

        mgr.delete(id: p1.id)
        XCTAssertEqual(mgr.presets.count, 1)
        XCTAssertEqual(mgr.presets.first?.name, "B")
    }
}

// MARK: - WBPreset Tests

final class WBPresetTests: XCTestCase {
    func testAutoKelvinIsNil() {
        XCTAssertNil(WBPreset.auto.kelvin)
    }

    func testDaylightIs5600K() {
        XCTAssertEqual(WBPreset.daylight.kelvin, 5600)
    }

    func testShadeWarmerThanCloudy() {
        XCTAssertGreaterThan(WBPreset.shade.kelvin ?? 0, WBPreset.cloudy.kelvin ?? 0)
    }

    func testTungstenIs3200K() {
        XCTAssertEqual(WBPreset.tungsten.kelvin, 3200)
    }

    func testAllPresetsHaveSystemImages() {
        for preset in WBPreset.allCases {
            XCTAssertFalse(preset.systemImage.isEmpty, "\(preset.rawValue) has no system image")
        }
    }

    func testAutoKelvinLabel() {
        XCTAssertEqual(WBPreset.auto.kelvinLabel, "AUTO")
    }

    func testDaylightKelvinLabel() {
        XCTAssertEqual(WBPreset.daylight.kelvinLabel, "5600K")
    }
}

// MARK: - CameraViewModel ciColor Tests

final class CameraViewModelCiColorTests: XCTestCase {
    func testCiColorGreen() {
        let c = CameraViewModel.ciColor(forPeakingColorName: "green")
        XCTAssertGreaterThan(c.green, 0.5)
        XCTAssertLessThan(c.red, 0.5)
    }

    func testCiColorWhite() {
        let c = CameraViewModel.ciColor(forPeakingColorName: "white")
        XCTAssertGreaterThan(c.red, 0.5)
        XCTAssertGreaterThan(c.green, 0.5)
        XCTAssertGreaterThan(c.blue, 0.5)
    }

    func testCiColorYellow() {
        let c = CameraViewModel.ciColor(forPeakingColorName: "yellow")
        XCTAssertGreaterThan(c.red, 0.5)
        XCTAssertGreaterThan(c.green, 0.5)
        XCTAssertLessThan(c.blue, 0.5)
    }

    func testCiColorDefaultIsRed() {
        let c = CameraViewModel.ciColor(forPeakingColorName: "unknown_value")
        XCTAssertGreaterThan(c.red, 0.5)
        XCTAssertLessThan(c.green, 0.5)
        XCTAssertLessThan(c.blue, 0.5)
    }
}

// MARK: - MeteringMode Tests

final class MeteringModeTests: XCTestCase {
    func testNextCycles() {
        XCTAssertEqual(MeteringMode.matrix.next, .center)
        XCTAssertEqual(MeteringMode.center.next, .spot)
        XCTAssertEqual(MeteringMode.spot.next, .highlightWeighted)
        XCTAssertEqual(MeteringMode.highlightWeighted.next, .matrix)
    }
}

// MARK: - Additional CaptureSettings formatting tests

final class CaptureSettingsExtraFormattingTests: XCTestCase {
    func testFractionalSeconds() {
        XCTAssertEqual(CaptureSettings.formatShutterSpeed(1.5), "1.5\"")
    }

    func testWholeSeconds() {
        XCTAssertEqual(CaptureSettings.formatShutterSpeed(30.0), "30\"")
    }
}
