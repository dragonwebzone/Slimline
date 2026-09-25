import Foundation
import Testing

@testable import MyApp

/// Tests for the order things appear in.
///
/// Ordering looks cosmetic but isn't: the user opened the app to free space, so a list that
/// doesn't lead with the biggest items is hiding the answer they came for. And "keeper first"
/// is the kind of rule a later refactor drops without anyone noticing.
@MainActor
@Suite("Result ordering")
struct OrderingTests {

    private func record(id: String, bytes: Int64?) -> AssetRecord {
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

    @Test("The keeper leads regardless of its size")
    func keeperComesFirst() {
        let assets = [
            record(id: "small-keeper", bytes: 1_000),
            record(id: "big", bytes: 9_000),
            record(id: "medium", bytes: 5_000),
        ]

        let ordered = ScanCoordinator.ordered(assets, keeper: "small-keeper")

        #expect(ordered.map(\.id) == ["small-keeper", "big", "medium"])
    }

    @Test("Everything after the keeper is largest first")
    func othersAreLargestFirst() {
        let assets = [
            record(id: "a", bytes: 2_000),
            record(id: "keeper", bytes: 100),
            record(id: "b", bytes: 8_000),
            record(id: "c", bytes: 5_000),
        ]

        let ordered = ScanCoordinator.ordered(assets, keeper: "keeper")

        #expect(ordered.map(\.id) == ["keeper", "b", "c", "a"])
    }

    @Test("Unknown sizes sort last rather than first")
    func unsizedAssetsSortLast() {
        // A `nil` size must not read as a huge file and jump the queue.
        let assets = [
            record(id: "unknown", bytes: nil),
            record(id: "keeper", bytes: 100),
            record(id: "known", bytes: 3_000),
        ]

        let ordered = ScanCoordinator.ordered(assets, keeper: "keeper")

        #expect(ordered.map(\.id) == ["keeper", "known", "unknown"])
    }

    @Test("A missing keeper doesn't lose the other photos")
    func absentKeeperStillReturnsOthers() {
        let assets = [record(id: "a", bytes: 1_000), record(id: "b", bytes: 2_000)]

        let ordered = ScanCoordinator.ordered(assets, keeper: "gone")

        #expect(ordered.map(\.id) == ["b", "a"])
    }

    @Test("Groups are ranked by what they would actually free")
    func groupsRankByReclaimable() {
        // Reclaimable counts the non-keepers only, so a big group of small photos can outrank a
        // small group of large ones — which is the figure the user is choosing between.
        let small = SimilarPhotoGroup(
            id: "small",
            assets: [record(id: "s1", bytes: 10_000), record(id: "s2", bytes: 1_000)],
            bestAssetID: "s1"
        )
        let large = SimilarPhotoGroup(
            id: "large",
            assets: [
                record(id: "l1", bytes: 1_000),
                record(id: "l2", bytes: 4_000),
                record(id: "l3", bytes: 4_000),
            ],
            bestAssetID: "l1"
        )

        let ranked = [small, large].sorted { $0.reclaimableBytes > $1.reclaimableBytes }

        #expect(small.reclaimableBytes == 1_000)
        #expect(large.reclaimableBytes == 8_000)
        #expect(ranked.map(\.id) == ["large", "small"])
    }
}
