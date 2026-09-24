import Testing
@testable import Fexer

struct CameraTextTests {
    @Test func formatsSlowShuttersInSeconds() {
        #expect(CameraText.shutter(2) == "2s")
        #expect(CameraText.shutter(1) == "1s")
    }

    @Test func formatsFastShuttersAsFractions() {
        #expect(CameraText.shutter(1.0 / 125) == "1/125")
        #expect(CameraText.shutter(1.0 / 8000) == "1/8000")
    }

    @Test func formatsInvalidValuesAsPlaceholder() {
        #expect(CameraText.shutter(0) == "–")
        #expect(CameraText.shutter(-1) == "–")
        #expect(CameraText.shutter(.nan) == "–")
    }
}
