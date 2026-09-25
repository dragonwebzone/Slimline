import Foundation
import Testing

@testable import MyApp

/// Tests that a keeper the user chose survives the next scan.
///
/// The failure these guard against is silent: the app re-derives its own pick on every scan, so
/// without this a user's star is undone by pull-to-refresh and nobody notices until they delete
/// the wrong photo.
@MainActor
@Suite("Keeper preferences")
struct KeeperPreferencesTests {

    /// A throwaway defaults suite per test, so tests never read each other's choices or the
    /// app's real ones.
    private func freshDefaults() -> UserDefaults {
        let name = "slimline-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func record(id: String, bytes: Int64 = 1_000) -> AssetRecord {
        AssetRecord(
            id: id,
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: nil,
            pixelWidth: 4000,
            pixelHeight: 3000,
            isVideo: false,
            isScreenshot: false,
            isScreenRecording: false,
            duration: 0,
            isFavorite: false,
            hasAdjustments: false,
            byteSize: bytes
        )
    }

    private func group(_ ids: [String], keeper: String) -> SimilarPhotoGroup {
        SimilarPhotoGroup(id: keeper, assets: ids.map { record(id: $0) }, bestAssetID: keeper)
    }

    @Test("A chosen keeper overrides the scan's pick")
    func preferenceOverridesScan() {
        let scanned = [group(["a", "b", "c"], keeper: "a")]

        let applied = KeeperPreferences.applying(["c"], to: scanned)

        #expect(applied[0].bestAssetID == "c")
        #expect(applied[0].assets.first?.id == "c")
    }

    @Test("Groups without a preference keep the scan's pick")
    func untouchedGroupsStayPut() {
        let scanned = [group(["a", "b"], keeper: "a"), group(["x", "y"], keeper: "x")]

        let applied = KeeperPreferences.applying(["b"], to: scanned)

        #expect(applied[0].bestAssetID == "b")
        #expect(applied[1].bestAssetID == "x")
    }

    @Test("Group identity survives an override")
    func overrideKeepsGroupID() {
        // CleanPlan tracks groups by ID for its never-empty rule, so an override must not
        // silently turn one group into another.
        let applied = KeeperPreferences.applying(["b"], to: [group(["a", "b"], keeper: "a")])

        #expect(applied[0].id == "a")
    }

    @Test("Choices persist across instances")
    func choicesPersist() {
        let defaults = freshDefaults()
        KeeperPreferences(defaults: defaults).preferPhoto("b", over: ["a", "b", "c"])

        // A new instance stands in for a relaunch.
        #expect(KeeperPreferences(defaults: defaults).photos == ["b"])
    }

    @Test("A new choice replaces the old one within the same set")
    func rechoosingReplaces() {
        // Otherwise both would be remembered and the next scan would have to guess.
        let preferences = KeeperPreferences(defaults: freshDefaults())

        preferences.preferPhoto("a", over: ["a", "b", "c"])
        preferences.preferPhoto("c", over: ["a", "b", "c"])

        #expect(preferences.photos == ["c"])
    }

    @Test("Choices in different sets don't disturb each other")
    func separateSetsCoexist() {
        let preferences = KeeperPreferences(defaults: freshDefaults())

        preferences.preferPhoto("a", over: ["a", "b"])
        preferences.preferPhoto("x", over: ["x", "y"])

        #expect(preferences.photos == ["a", "x"])
    }

    @Test("Pruning forgets photos that no longer exist")
    func pruneDropsDeleted() {
        let preferences = KeeperPreferences(defaults: freshDefaults())
        preferences.preferPhoto("a", over: ["a", "b"])
        preferences.preferPhoto("x", over: ["x", "y"])

        preferences.prunePhotos(keeping: ["x", "y"])

        #expect(preferences.photos == ["x"])
    }

    @Test("A chosen contact becomes the primary on the next scan")
    func contactPreferenceApplies() {
        let scanned = [
            DuplicateContactGroup(
                id: "g",
                contacts: [
                    ContactRecord(id: "rich", givenName: "Ada", phoneNumbers: ["9876543210"]),
                    ContactRecord(id: "mine", givenName: "Ada"),
                ],
                primaryContactID: "rich"
            ),
        ]

        let applied = KeeperPreferences.applying(["mine"], to: scanned)

        #expect(applied[0].primaryContactID == "mine")
        #expect(applied[0].duplicates.map(\.id) == ["rich"])
    }
}
