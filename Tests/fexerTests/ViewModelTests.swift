import XCTest
import UIKit
import CoreImage
@testable import fexer

class StylePreviewRendererTests: XCTestCase {
    var renderer: StylePreviewRenderer!
    
    override func setUp() async throws {
        renderer = StylePreviewRenderer.shared
    }
    
    override func tearDown() async throws {
        renderer = nil
    }
    
    func testStylePreviewRendererInitialization() {
        XCTAssertNotNil(renderer)
    }
    
    func testThumbnailGeneration() {
        let style = PhotoStyle(
            id: UUID(),
            name: "Portra 400",
            category: .film,
            lutFileName: "kodak_portra_400.cube",
            baseIntensity: 0.85,
            description: "Warm skin tones, subtle grain"
        )
        
        let expectation = XCTestExpectation(description: "Thumbnail generation")
        
        renderer.thumbnail(for: style) { image in
            XCTAssertNotNil(image)
            XCTAssertEqual(image?.size.width, 120)
            XCTAssertEqual(image?.size.height, 90)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testThumbnailCache() {
        let style = PhotoStyle(
            id: UUID(),
            name: "Portra 400",
            category: .film,
            lutFileName: "kodak_portra_400.cube",
            baseIntensity: 0.85,
            description: "Warm skin tones, subtle grain"
        )
        
        let expectation1 = XCTestExpectation(description: "First thumbnail generation")
        
        renderer.thumbnail(for: style) { image1 in
            XCTAssertNotNil(image1)
            
            let expectation2 = XCTestExpectation(description: "Second thumbnail generation (should use cache)")
            
            renderer.thumbnail(for: style) { image2 in
                XCTAssertNotNil(image2)
                XCTAssertEqual(image1, image2)
                expectation2.fulfill()
            }
            
            expectation1.fulfill()
        }
        
        wait(for: [expectation1, expectation2], timeout: 5.0)
    }
    
    func testThumbnailWithDifferentSizes() {
        let style = PhotoStyle(
            id: UUID(),
            name: "Portra 400",
            category: .film,
            lutFileName: "kodak_portra_400.cube",
            baseIntensity: 0.85,
            description: "Warm skin tones, subtle grain"
        )
        
        let expectation = XCTestExpectation(description: "Thumbnail generation with custom size")
        
        renderer.thumbnail(for: style, size: CGSize(width: 200, height: 150)) { image in
            XCTAssertNotNil(image)
            XCTAssertEqual(image?.size.width, 200)
            XCTAssertEqual(image?.size.height, 150)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testRendererSingleton() {
        let renderer1 = StylePreviewRenderer.shared
        let renderer2 = StylePreviewRenderer.shared
        
        XCTAssertEqual(renderer1, renderer2)
    }

class StylesManagerTests: XCTestCase {
    var stylesManager: StylesManager!
    
    override func setUp() async throws {
        stylesManager = StylesManager()
    }
    
    override func tearDown() async throws {
        stylesManager = nil
    }
    
    func testStylesManagerInitialization() {
        XCTAssertNotNil(stylesManager)
        XCTAssertNil(stylesManager.activeStyle)
        XCTAssertEqual(stylesManager.styleIntensity, 0.85)
        XCTAssertEqual(stylesManager.adjustments.exposure, 0)
    }
    
    func testAllStyles() {
        XCTAssertFalse(stylesManager.allStyles.isEmpty)
        XCTAssertTrue(stylesManager.allStyles[.film]?.count ?? 0 > 0)
        XCTAssertTrue(stylesManager.allStyles[.genre]?.count ?? 0 > 0)
        XCTAssertTrue(stylesManager.allStyles[.mood]?.count ?? 0 > 0)
    }
    
    func testSelectStyle() {
        let style = PhotoStyle(
            id: UUID(),
            name: "Test Style",
            category: .film,
            lutFileName: "test.cube",
            baseIntensity: 0.8,
            description: "Test style"
        )
        
        stylesManager.selectStyle(style)
        XCTAssertEqual(stylesManager.activeStyle?.id, style.id)
        
        stylesManager.selectStyle(nil)
        XCTAssertNil(stylesManager.activeStyle)
    }
    
    func testSelectStyleNone() {
        stylesManager.selectStyle(PhotoStyle.none)
        XCTAssertNil(stylesManager.activeStyle)
        XCTAssertEqual(stylesManager.adjustments.exposure, 0)
    }
    
    func testProcessFrameWithoutSmartStyles() {
        stylesManager.isSmartStylesEnabled = false

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 100,
            kCVPixelBufferHeightKey as String: 100
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        stylesManager.processFrame(pb)
        XCTAssertTrue(true)
    }
    
    func testAdjustmentsResetOnStyleChange() {
        var adjustments = StyleAdjustments()
        adjustments.exposure = 0.5
        adjustments.contrast = 0.3
        
        stylesManager.adjustments = adjustments
        
        let style = PhotoStyle(
            id: UUID(),
            name: "Test Style",
            category: .film,
            lutFileName: "test.cube",
            baseIntensity: 0.8,
            description: "Test style"
        )
        
        stylesManager.selectStyle(style)
        
        XCTAssertEqual(stylesManager.adjustments.exposure, 0)
        XCTAssertEqual(stylesManager.adjustments.contrast, 0)
    }
}

class CameraViewModelTests: XCTestCase {
    var cameraManager: CameraManager!
    var stylesManager: StylesManager!
    var cameraViewModel: CameraViewModel!
    
    override func setUp() async throws {
        cameraManager = CameraManager()
        stylesManager = StylesManager()
        cameraViewModel = CameraViewModel(cameraManager: cameraManager, stylesManager: stylesManager)
    }
    
    override func tearDown() async throws {
        cameraManager = nil
        stylesManager = nil
        cameraViewModel = nil
    }
    
    func testCameraViewModelInitialization() {
        XCTAssertNotNil(cameraManager)
        XCTAssertNotNil(stylesManager)
        XCTAssertNotNil(cameraViewModel)
    }
    
    func testCameraViewModelUIState() {
        XCTAssertFalse(cameraViewModel.isPanelExpanded)
        XCTAssertEqual(cameraViewModel.activeModeIndex, 0)
        XCTAssertFalse(cameraViewModel.isFocusLocked)
        XCTAssertEqual(cameraViewModel.focusIndicatorPosition, CGPoint.zero)
        XCTAssertFalse(cameraViewModel.showFocusIndicator)
        XCTAssertEqual(cameraViewModel.zoomLevel, 1.0)
    }
    
    func testCameraViewModelAELockComputedProperty() {
        XCTAssertEqual(cameraViewModel.isAELocked, cameraManager.captureSettings.isAELocked)
    }
    
    func testCameraViewModelTimerState() {
        XCTAssertEqual(cameraViewModel.timerCountdown, 0)
        XCTAssertFalse(cameraViewModel.isTimerActive)
    }
    
    func testCameraViewModelHistogram() {
        XCTAssertEqual(cameraViewModel.histogram.red.count, 0)
        XCTAssertEqual(cameraViewModel.histogram.green.count, 0)
        XCTAssertEqual(cameraViewModel.histogram.blue.count, 0)
        XCTAssertEqual(cameraViewModel.histogram.luma.count, 0)
    }
    
    func testCameraViewModelExposureCompensation() {
        XCTAssertEqual(cameraViewModel.accumulatedExposureBias, 0)
    }
    
    func testCameraViewModelModeSelection() {
        XCTAssertEqual(cameraViewModel.activeMode, ShootingMode.photo)

        var crop = CropRatio.full.rawValue
        var timer = 0
        let cropBinding = Binding(get: { crop }, set: { crop = $0 })
        let timerBinding = Binding(get: { timer }, set: { timer = $0 })

        cameraViewModel.selectMode(index: 1, cropRatioRaw: cropBinding, selfTimerDelay: timerBinding)
        XCTAssertEqual(cameraViewModel.activeMode, ShootingMode.portrait)

        cameraViewModel.selectMode(index: 0, cropRatioRaw: cropBinding, selfTimerDelay: timerBinding)
        XCTAssertEqual(cameraViewModel.activeMode, ShootingMode.photo)
    }

    func testCameraViewModelSelectModeInvalidIndex() {
        var crop = CropRatio.full.rawValue
        var timer = 0
        let cropBinding = Binding(get: { crop }, set: { crop = $0 })
        let timerBinding = Binding(get: { timer }, set: { timer = $0 })

        cameraViewModel.selectMode(index: -1, cropRatioRaw: cropBinding, selfTimerDelay: timerBinding)
        XCTAssertEqual(cameraViewModel.activeMode, ShootingMode.photo)

        cameraViewModel.selectMode(index: 100, cropRatioRaw: cropBinding, selfTimerDelay: timerBinding)
        XCTAssertEqual(cameraViewModel.activeMode, ShootingMode.photo)
    }
    
    func testCameraViewModelSyncOverlaysToProcessor() {
        cameraViewModel.syncOverlaysToProcessor(focusPeaking: true, zebra: true, falseColor: true)
        
        XCTAssertTrue(cameraManager.processor.isFocusPeakingEnabled)
        XCTAssertTrue(cameraManager.processor.isZebraEnabled)
        XCTAssertTrue(cameraManager.processor.isFalseColorEnabled)
    }
    
    func testCameraViewModelDoubleTapReset() {
        let initialISO = cameraManager.captureSettings.isAutoISO
        let initialShutter = cameraManager.captureSettings.isAutoShutter
        let initialFocus = cameraManager.captureSettings.isAutoFocus
        let initialWB = cameraManager.captureSettings.isAutoWhiteBalance
        
        cameraViewModel.handleDoubleTapReset()
        
        XCTAssertEqual(cameraManager.captureSettings.isAutoISO, initialISO)
        XCTAssertEqual(cameraManager.captureSettings.isAutoShutter, initialShutter)
        XCTAssertEqual(cameraManager.captureSettings.isAutoFocus, initialFocus)
        XCTAssertEqual(cameraManager.captureSettings.isAutoWhiteBalance, initialWB)
        XCTAssertEqual(cameraManager.captureSettings.exposureCompensation, 0)
        XCTAssertEqual(cameraViewModel.accumulatedExposureBias, 0)
    }
    
    func testCameraViewModelBrightnessSwipe() {
        let initialBias = cameraViewModel.accumulatedExposureBias
        
        cameraViewModel.handleBrightnessSwipe(delta: 0.5)
        XCTAssertEqual(cameraViewModel.accumulatedExposureBias, initialBias + 0.5)
        
        cameraViewModel.handleBrightnessSwipe(delta: -0.3)
        XCTAssertEqual(cameraViewModel.accumulatedExposureBias, initialBias + 0.2)
    }
    
    func testCameraViewModelZoom() {
        let initialZoom = cameraViewModel.zoomLevel
        
        cameraViewModel.handlePinchZoom(scale: 1.5, velocity: 0)
        XCTAssertEqual(cameraViewModel.zoomLevel, 1.5)
        
        cameraViewModel.handlePinchZoom(scale: 0.5, velocity: 0)
        XCTAssertEqual(cameraViewModel.zoomLevel, 0.5)
    }
    
    func testCameraViewModelZoomClamping() {
        cameraViewModel.handlePinchZoom(scale: 20.0, velocity: 0)
        XCTAssertEqual(cameraViewModel.zoomLevel, 15.0) // Max zoom is 15.0
        
        cameraViewModel.handlePinchZoom(scale: 0.2, velocity: 0)
        XCTAssertEqual(cameraViewModel.zoomLevel, 0.5) // Min zoom is 0.5
    }
}