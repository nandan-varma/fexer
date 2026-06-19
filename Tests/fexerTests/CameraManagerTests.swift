import XCTest
import AVFoundation
import CoreImage

class CameraManagerTests: XCTestCase {
    var cameraManager: CameraManager!
    var stylesManager: StylesManager!
    var cameraViewModel: CameraViewModel!
    
    override func setUp() async throws {
        // Initialize managers
        cameraManager = CameraManager()
        stylesManager = StylesManager()
        cameraViewModel = CameraViewModel(cameraManager: cameraManager, stylesManager: stylesManager)
    }
    
    override func tearDown() async throws {
        // Clean up
        cameraManager = nil
        stylesManager = nil
        cameraViewModel = nil
    }
    
    func testCameraManagerInitialization() {
        XCTAssertNotNil(cameraManager)
        XCTAssertNotNil(stylesManager)
        XCTAssertNotNil(cameraViewModel)
    }
    
    func testCaptureSettingsInitialization() {
        XCTAssertEqual(cameraManager.captureSettings.isoValue, 200)
        XCTAssertEqual(cameraManager.captureSettings.isAELocked, false)
        XCTAssertEqual(cameraManager.captureSettings.isAutoISO, true)
        XCTAssertEqual(cameraManager.captureSettings.isAutoShutter, true)
        XCTAssertEqual(cameraManager.captureSettings.isAutoFocus, true)
        XCTAssertEqual(cameraManager.captureSettings.isAutoWhiteBalance, true)
    }
    
    func testStyleCategoryEnum() {
        XCTAssertEqual(StyleCategory.film.rawValue, "Film")
        XCTAssertEqual(StyleCategory.genre.rawValue, "Genre")
        XCTAssertEqual(StyleCategory.mood.rawValue, "Mood")
        XCTAssertEqual(StyleCategory.custom.rawValue, "Custom")
    }
    
    func testPhotoStyleCatalog() {
        XCTAssertFalse(PhotoStyle.catalog.isEmpty)
        XCTAssertTrue(PhotoStyle.catalog.contains { $0.name == "Portra 400" })
        XCTAssertTrue(PhotoStyle.catalog.contains { $0.name == "Tri-X BW" })
    }
    
    func testCaptureFormatEnum() {
        XCTAssertEqual(CaptureFormat.jpeg.rawValue, "JPEG")
        XCTAssertEqual(CaptureFormat.raw.rawValue, "RAW")
        XCTAssertEqual(CaptureFormat.rawPlusJpeg.rawValue, "RAW+JPEG")
    }
    
    func testMeteringModeEnum() {
        XCTAssertEqual(MeteringMode.matrix.rawValue, "Matrix")
        XCTAssertEqual(MeteringMode.center.rawValue, "Center")
        XCTAssertEqual(MeteringMode.spot.rawValue, "Spot")
    }
    
    func testShootingModeEnum() {
        XCTAssertEqual(ShootingMode.photo.rawValue, "Photo")
        XCTAssertEqual(ShootingMode.portrait.rawValue, "Portrait")
        XCTAssertEqual(ShootingMode.longExposure.rawValue, "Long Exp")
    }
    
    func testQuickAccessItemEnum() {
        XCTAssertEqual(QuickAccessItem.flash.rawValue, "Flash")
        XCTAssertEqual(QuickAccessItem.timer.rawValue, "Timer")
        XCTAssertEqual(QuickAccessItem.grid.rawValue, "Grid")
        XCTAssertEqual(QuickAccessItem.histogram.rawValue, "Histogram")
        XCTAssertEqual(QuickAccessItem.flipCamera.rawValue, "Flip")
    }
    
    func testCaptureSettingsShutterSpeedFormatting() {
        let settings = CaptureSettings()
        XCTAssertEqual(settings.shutterSpeedDisplayString, "1/250")
        
        let fastSpeed = CMTime(value: 1, timescale: 8000)
        XCTAssertEqual(settings.formatShutterSpeed(CMTimeGetSeconds(fastSpeed)), "1/8000")
        
        let slowSpeed = CMTime(value: 2, timescale: 1)
        XCTAssertEqual(settings.formatShutterSpeed(CMTimeGetSeconds(slowSpeed)), "2s")
    }
    
    func testComparableClamping() {
        let value: Float = 150
        let clamped = value.fxClamped(to: 100...200)
        XCTAssertEqual(clamped, 150)
        
        let tooLow = value.fxClamped(to: 200...300)
        XCTAssertEqual(tooLow, 200)
        
        let tooHigh = value.fxClamped(to: 50...100)
        XCTAssertEqual(tooHigh, 100)
    }
    
    func testStyleAdjustments() {
        var adjustments = StyleAdjustments()
        XCTAssertEqual(adjustments.exposure, 0)
        XCTAssertEqual(adjustments.contrast, 0)
        XCTAssertEqual(adjustments.saturation, 0)
        XCTAssertEqual(adjustments.warmth, 0)
        
        adjustments.exposure = -0.5
        adjustments.contrast = 0.2
        adjustments.saturation = 0.8
        adjustments.warmth = 0.3
        
        XCTAssertEqual(adjustments.exposure, -0.5)
        XCTAssertEqual(adjustments.contrast, 0.2)
        XCTAssertEqual(adjustments.saturation, 0.8)
        XCTAssertEqual(adjustments.warmth, 0.3)
    }
    
    func testCaptureSettingsEquatable() {
        let settings1 = CaptureSettings()
        let settings2 = CaptureSettings()
        
        XCTAssertEqual(settings1, settings2)
        
        var settings3 = CaptureSettings()
        settings3.isoValue = 400
        XCTAssertNotEqual(settings1, settings3)
    }
    
    func testPhotoStyleHashable() {
        let style1 = PhotoStyle(
            id: UUID(),
            name: "Test Style",
            category: .film,
            lutFileName: "test.cube",
            baseIntensity: 0.8,
            description: "Test description"
        )
        
        let style2 = PhotoStyle(
            id: style1.id,
            name: "Test Style",
            category: .film,
            lutFileName: "test.cube",
            baseIntensity: 0.8,
            description: "Test description"
        )
        
        XCTAssertEqual(style1, style2)
        XCTAssertEqual(style1.hashValue, style2.hashValue)
    }
    
    func testCaptureSettingsCaptureFormatAllCases() {
        XCTAssertEqual(CaptureFormat.allCases.count, 3)
        XCTAssertTrue(CaptureFormat.allCases.contains(.jpeg))
        XCTAssertTrue(CaptureFormat.allCases.contains(.raw))
        XCTAssertTrue(CaptureFormat.allCases.contains(.rawPlusJpeg))
    }
    
    func testShootingModeAllCases() {
        XCTAssertEqual(ShootingMode.allCases.count, 8)
        XCTAssertTrue(ShootingMode.allCases.contains(.photo))
        XCTAssertTrue(ShootingMode.allCases.contains(.portrait))
        XCTAssertTrue(ShootingMode.allCases.contains(.longExposure))
    }
    
    func testStyleCategoryAllCases() {
        XCTAssertEqual(StyleCategory.allCases.count, 4)
        XCTAssertTrue(StyleCategory.allCases.contains(.film))
        XCTAssertTrue(StyleCategory.allCases.contains(.genre))
        XCTAssertTrue(StyleCategory.allCases.contains(.mood))
        XCTAssertTrue(StyleCategory.allCases.contains(.custom))
    }
    
    func testMeteringModeAllCases() {
        XCTAssertEqual(MeteringMode.allCases.count, 3)
        XCTAssertTrue(MeteringMode.allCases.contains(.matrix))
        XCTAssertTrue(MeteringMode.allCases.contains(.center))
        XCTAssertTrue(MeteringMode.allCases.contains(.spot))
    }
    
    func testQuickAccessItemAllCases() {
        XCTAssertEqual(QuickAccessItem.allCases.count, 12)
        XCTAssertTrue(QuickAccessItem.allCases.contains(.flash))
        XCTAssertTrue(QuickAccessItem.allCases.contains(.timer))
        XCTAssertTrue(QuickAccessItem.allCases.contains(.grid))
        XCTAssertTrue(QuickAccessItem.allCases.contains(.histogram))
        XCTAssertTrue(QuickAccessItem.allCases.contains(.flipCamera))
    }
}

// MARK: - Helper Extensions for Testing

extension AVCaptureDevice {
    static func mockDevice() -> AVCaptureDevice {
        // This is a mock implementation for testing
        // In a real test environment, you would need proper mocking
        fatalError("Use dependency injection for testing")
    }
}