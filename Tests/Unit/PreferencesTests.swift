import Testing
import Foundation
@testable import Fexer

@MainActor
struct PreferencesTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsWithDefaultsWhenNothingStored() {
        let defaults = freshDefaults("fexer.tests.fresh")
        let store = PreferenceStore(defaults: defaults)
        #expect(store.value == Preferences())
    }

    @Test func migratesLegacyKeysWhenNoModernDataExists() {
        let name = "fexer.tests.migration"
        let defaults = freshDefaults(name)
        defaults.set(true, forKey: "showGrid")
        defaults.set(true, forKey: "showReviewAfterShot")
        defaults.set("JPEG", forKey: "defaultCaptureFormat")
        let store = PreferenceStore(defaults: defaults)
        #expect(store.value.grid == .thirds)
        #expect(store.value.reviewAfterCapture == true)
        #expect(store.value.format == .jpeg)
    }

    @Test func persistsAndReloadsAcrossInstances() {
        let name = "fexer.tests.persist"
        let defaults = freshDefaults(name)
        let store = PreferenceStore(defaults: defaults)
        store.value.haptics = false
        store.value.burstCount = 20
        let reloaded = PreferenceStore(defaults: defaults)
        #expect(reloaded.value.haptics == false)
        #expect(reloaded.value.burstCount == 20)
    }

    @Test func resetRestoresDefaults() {
        let name = "fexer.tests.reset"
        let defaults = freshDefaults(name)
        let store = PreferenceStore(defaults: defaults)
        store.value.haptics = false
        store.reset()
        #expect(store.value == Preferences())
    }
}
