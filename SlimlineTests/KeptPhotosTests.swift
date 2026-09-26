import Foundation
import Testing

@testable import MyApp

/// Tests that a photo the user kept stays out of the results, and can be brought back.
@MainActor
@Suite("Kept photos")
struct KeptPhotosTests {

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

    @Test("Kept photos survive a relaunch")
    func persists() {
        let defaults = freshDefaults()
        KeptPhotos(defaults: defaults).keep(["a", "b"])

        let reloaded = KeptPhotos(defaults: defaults)
        #expect(reloaded.ids == ["a", "b"])
    }

    @Test("Releasing a photo lets it be suggested again, and that survives a relaunch")
    func releaseRoundTrips() {
        let defaults = freshDefaults()
        let kept = KeptPhotos(defaults: defaults)
        kept.keep(["a", "b"])
        kept.release(["a"])

        #expect(kept.contains("a") == false)
        #expect(KeptPhotos(defaults: defaults).ids == ["b"])
    }

    @Test("Pruning forgets photos that have left the library")
    func pruneDropsDeleted() {
        let kept = KeptPhotos(defaults: freshDefaults())
        kept.keep(["a", "gone"])
        kept.prune(keeping: ["a", "other"])

        #expect(kept.ids == ["a"])
    }

    @Test("A kept photo leaves its group, and the rest stays grouped")
    func keptPhotoLeavesGroup() {
        let group = SimilarPhotoGroup(
            id: "g",
            assets: [record(id: "a"), record(id: "b"), record(id: "c")],
            bestAssetID: "a"
        )

        let result = ScanCoordinator.removing(["c"], from: [group])

        #expect(result.count == 1)
        #expect(result[0].assets.map(\.id) == ["a", "b"])
        #expect(result[0].bestAssetID == "a")
    }

    @Test("Keeping the keeper hands protection to another photo")
    func keptKeeperIsReplaced() {
        let group = SimilarPhotoGroup(
            id: "g",
            assets: [record(id: "a"), record(id: "b"), record(id: "c")],
            bestAssetID: "a"
        )

        let result = ScanCoordinator.removing(["a"], from: [group])

        // A group must always have a protected member, or "select extras" could empty it.
        #expect(result.count == 1)
        #expect(result[0].assets.contains { $0.id == result[0].bestAssetID })
        #expect(result[0].bestAssetID != "a")
    }

    @Test("A group reduced to one photo disappears")
    func singletonGroupIsDropped() {
        let group = SimilarPhotoGroup(
            id: "g",
            assets: [record(id: "a"), record(id: "b")],
            bestAssetID: "a"
        )

        #expect(ScanCoordinator.removing(["b"], from: [group]).isEmpty)
        #expect(ScanCoordinator.removing(["a", "b"], from: [group]).isEmpty)
    }
}
