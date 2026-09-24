import Testing
import Foundation
@testable import Fexer

struct CubeLUTTests {
    private func identityCube(size: Int) -> String {
        var lines = ["TITLE \"Identity\"", "LUT_3D_SIZE \(size)"]
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let step = Double(size - 1)
                    lines.append("\(Double(red) / step) \(Double(green) / step) \(Double(blue) / step)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func parsesValidCubeFile() throws {
        let cube = try CubeLUT.parse(identityCube(size: 2))
        #expect(cube.dimension == 2)
        #expect(cube.isValid)
        #expect(cube.rgba.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
    }

    @Test func rejectsMissingSize() {
        #expect(throws: CubeLUT.ParseError.missingSize) {
            _ = try CubeLUT.parse("0 0 0\n1 1 1")
        }
    }

    @Test func rejectsOutOfRangeSize() {
        #expect(throws: CubeLUT.ParseError.invalidSize) {
            _ = try CubeLUT.parse("LUT_3D_SIZE 1")
        }
        #expect(throws: CubeLUT.ParseError.invalidSize) {
            _ = try CubeLUT.parse("LUT_3D_SIZE 128")
        }
    }

    @Test func rejectsNonStandardDomain() {
        let text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 1\nDOMAIN_MAX 1 1 1\n" + identityCube(size: 2)
        #expect(throws: CubeLUT.ParseError.unsupportedDomain) {
            _ = try CubeLUT.parse(text)
        }
    }

    @Test func rejectsMalformedRow() {
        let text = "LUT_3D_SIZE 2\nnot a valid row\n" + String(repeating: "0 0 0\n", count: 7)
        #expect(throws: CubeLUT.ParseError.malformedLine(2)) {
            _ = try CubeLUT.parse(text)
        }
    }

    @Test func rejectsWrongEntryCount() {
        let text = "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 3)
        #expect(throws: CubeLUT.ParseError.wrongCount) {
            _ = try CubeLUT.parse(text)
        }
    }

    @Test func rejectsOversizedFile() {
        let huge = String(repeating: "0", count: 16_000_001)
        #expect(throws: CubeLUT.ParseError.tooLarge) {
            _ = try CubeLUT.parse(huge)
        }
    }

    @Test func ignoresCommentsAndTitle() throws {
        let text = "TITLE \"Sample\"\n# a comment\nLUT_3D_SIZE 2 # inline comment\n" + identityCube(size: 2).split(separator: "\n").dropFirst(2).joined(separator: "\n")
        let cube = try CubeLUT.parse(text)
        #expect(cube.dimension == 2)
    }

    @Test func invalidDimensionIsNotValid() {
        let cube = CubeLUT(dimension: 200, rgba: Data())
        #expect(!cube.isValid)
    }
}
