import Testing
@testable import Fexer

struct PhotoStyleTests {
    @Test func findReturnsOriginalForUnknownID() {
        #expect(PhotoStyle.find("does-not-exist").id == "original")
    }

    @Test func findReturnsMatchingStyle() {
        #expect(PhotoStyle.find("portra").name == "Portra 400")
    }

    @Test func allStyleIDsAreUnique() {
        let ids = PhotoStyle.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyNonOriginalStyleHasACubeFile() {
        for style in PhotoStyle.all where style.id != "original" {
            #expect(style.file != nil, "\(style.name) is missing a LUT file")
        }
    }
}
