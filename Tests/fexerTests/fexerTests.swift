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
        let result: Float = 0.5.fxClamped(to: 0...1)
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
        // Normalized histogram — middle bin should have the peak
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
        // All values should be ≤ 1 (normalized)
        for v in hist.red { XCTAssertLessThanOrEqual(v, 1.0) }
        for v in hist.green { XCTAssertLessThanOrEqual(v, 1.0) }
        for v in hist.blue { XCTAssertLessThanOrEqual(v, 1.0) }
        for v in hist.luma { XCTAssertLessThanOrEqual(v, 1.0) }
    }
}
