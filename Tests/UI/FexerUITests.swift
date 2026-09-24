import XCTest

final class FexerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    func testCameraLaunchesToReadyViewfinder() {
        let app = launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings"].exists)
        XCTAssertTrue(app.buttons["library"].exists)
    }

    func testCaptureAddsToLibrary() {
        let app = launch()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()
        // Capture completes asynchronously; the shutter re-enables once the save lands.
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        app.buttons["library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
    }

    func testOpeningACaptureFromLibraryShowsDetail() {
        let app = launch()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        app.buttons["library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        let firstCapture = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(firstCapture.waitForExistence(timeout: 5))
        firstCapture.tap()
        // A pushed detail screen shows a back button labeled with the previous screen's title.
        XCTAssertTrue(app.navigationBars.buttons["Library"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Library"].tap()
        app.buttons["Done"].tap()
    }

    func testSettingsOpensAndCloses() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 10))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }

    func testStylePickerOpensAndCloses() {
        let app = launch()
        XCTAssertTrue(app.buttons["styles"].waitForExistence(timeout: 10))
        app.buttons["styles"].tap()
        XCTAssertTrue(app.navigationBars["Photo styles"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["styles"].waitForExistence(timeout: 5))
    }

    func testTappingISOPillExpandsAndCollapsesInlineScrubber() {
        let app = launch()
        XCTAssertTrue(app.buttons["isoControl"].waitForExistence(timeout: 10))
        app.buttons["isoControl"].tap()
        // The scrubber takes over the top bar in place of the wordmark and settings gear —
        // no sheet, so the viewfinder and every other pill stay fully visible underneath.
        XCTAssertTrue(app.descendants(matching: .any)["ISO"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings"].exists)
        XCTAssertTrue(app.buttons["shutterControl"].exists)
        app.buttons["collapseControl"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }

    func testManualFocusScrubberAppearsWithViewfinderStillVisibleAndAutoReverts() {
        let app = launch()
        XCTAssertTrue(app.buttons["focusControl"].waitForExistence(timeout: 10))
        app.buttons["focusControl"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Focus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shutter"].exists)
        app.buttons["autoControl"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
    }

    func testPinchToZoomOnViewfinderDoesNotBreakCapture() {
        let app = launch()
        let viewfinder = app.otherElements.matching(NSPredicate(format: "label == %@", "Camera viewfinder. Tap to focus, pinch to zoom.")).firstMatch
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 10))
        viewfinder.pinch(withScale: 2, velocity: 1)
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
    }
}
