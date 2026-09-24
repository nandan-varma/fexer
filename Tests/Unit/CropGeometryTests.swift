import Testing
@testable import Fexer
import CoreGraphics

struct CropGeometryTests {
    @Test func squareCropCentersInLandscapeExtent() {
        let crop = CropGeometry.crop(in: CGRect(x: 0, y: 0, width: 400, height: 300), aspect: 1, zoom: 1, x: 0.5, y: 0.5)
        #expect(crop.width == 300)
        #expect(crop.height == 300)
        #expect(crop.minX == 50)
        #expect(crop.minY == 0)
    }

    @Test func zoomShrinksCropAroundCenter() {
        let full = CropGeometry.crop(in: CGRect(x: 0, y: 0, width: 400, height: 400), aspect: 1, zoom: 1, x: 0.5, y: 0.5)
        let zoomed = CropGeometry.crop(in: CGRect(x: 0, y: 0, width: 400, height: 400), aspect: 1, zoom: 2, x: 0.5, y: 0.5)
        #expect(zoomed.width == full.width / 2)
        #expect(zoomed.midX == full.midX)
    }

    @Test func degenerateExtentReturnsZero() {
        #expect(CropGeometry.crop(in: .null, aspect: 1, zoom: 1, x: 0, y: 0) == .zero)
        #expect(CropGeometry.crop(in: .zero, aspect: 1, zoom: 1, x: 0, y: 0) == .zero)
    }

    @Test func outOfRangeInputsAreClampedNotCrashed() {
        let crop = CropGeometry.crop(in: CGRect(x: 0, y: 0, width: 400, height: 400), aspect: 1, zoom: 99, x: -5, y: 5)
        #expect(crop.width > 0 && crop.width.isFinite)
    }

    @Test func straightenedSizeShrinksToFitInsideRotatedFrame() {
        let size = CropGeometry.straightenedSize(CGSize(width: 400, height: 300), radians: .pi / 12)
        #expect(size.width < 400)
        #expect(size.height < 300)
        #expect(abs(size.width / size.height - 400.0 / 300.0) < 0.0001)
    }

    @Test func straightenedSizeWithNoRotationReturnsOriginal() {
        let size = CropGeometry.straightenedSize(CGSize(width: 400, height: 300), radians: 0)
        #expect(abs(size.width - 400) < 0.001)
        #expect(abs(size.height - 300) < 0.001)
    }

    @Test func focusPointMapsViewCenterToImageCenter() {
        let point = CropGeometry.focusPoint(CGPoint(x: 200, y: 300), view: CGSize(width: 400, height: 600), image: CGSize(width: 800, height: 1200), mirrored: false)
        #expect(abs(point.x - 0.5) < 0.001)
        #expect(abs(point.y - 0.5) < 0.001)
    }

    @Test func focusPointMirrorsForFrontCamera() {
        let normal = CropGeometry.focusPoint(CGPoint(x: 100, y: 300), view: CGSize(width: 400, height: 600), image: CGSize(width: 800, height: 1200), mirrored: false)
        let mirrored = CropGeometry.focusPoint(CGPoint(x: 100, y: 300), view: CGSize(width: 400, height: 600), image: CGSize(width: 800, height: 1200), mirrored: true)
        #expect(abs((normal.y + mirrored.y) - 1) < 0.001)
    }
}
