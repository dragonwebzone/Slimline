import Foundation
import Testing

@testable import MyApp

/// Tests for the pure grouping logic.
///
/// This is the only place the scan algorithm gets real coverage: the simulator has almost no
/// photos, so synthetic records are how we verify bucketing and grouping behave before trusting
/// the pipeline on a real device.
@Suite("Photo grouping")
struct PhotoGroupingTests {

    // MARK: - Helpers

    /// Builds a record without touching PhotoKit.
    private func record(
        id: String,
        secondsFromEpoch: TimeInterval? = 0,
        width: Int = 4000,
        height: Int = 3000,
        bytes: Int64? = 1_000_000,
        isFavorite: Bool = false,
        hasAdjustments: Bool = false,
        isVideo: Bool = false
    ) -> AssetRecord {
        AssetRecord(
            id: id,
            creationDate: secondsFromEpoch.map { Date(timeIntervalSince1970: $0) },
            modificationDate: nil,
            pixelWidth: width,
            pixelHeight: height,
            isVideo: isVideo,
            isScreenshot: false,
            isScreenRecording: false,
            duration: 0,
            isFavorite: isFavorite,
            hasAdjustments: hasAdjustments,
            byteSize: bytes
        )
    }

    // MARK: - Union-find

    @Test("Transitive matches collapse into one group")
    func unionFindIsTransitive() {
        var unionFind = UnionFind(count: 4)
        unionFind.union(0, 1)
        unionFind.union(1, 2)

        let clusters = unionFind.clusters()

        // A-B and B-C were matched separately; C must still end up with A.
        #expect(clusters.count == 1)
        #expect(clusters[0] == [0, 1, 2])
    }

    @Test("Unmatched elements form no group")
    func unionFindIgnoresSingletons() {
        var unionFind = UnionFind(count: 3)
        #expect(unionFind.clusters().isEmpty)
    }

    // MARK: - Bucketing

    @Test("Photos taken seconds apart land in the same bucket")
    func burstsBucketTogether() {
        let records = [
            record(id: "a", secondsFromEpoch: 0),
            record(id: "b", secondsFromEpoch: 3),
            record(id: "c", secondsFromEpoch: 6),
        ]

        let buckets = PhotoGrouping.candidateBuckets(for: records)

        #expect(buckets.count == 1)
        #expect(buckets[0].count == 3)
    }

    @Test("Photos taken far apart are never compared")
    func distantPhotosSplit() {
        let records = [
            record(id: "a", secondsFromEpoch: 0),
            record(id: "b", secondsFromEpoch: 5_000),
        ]

        // Both buckets would be singletons, which are dropped entirely.
        #expect(PhotoGrouping.candidateBuckets(for: records).isEmpty)
    }

    @Test("A long burst chains into one bucket even across the window length")
    func longBurstChains() {
        // Each gap is under the window, so the whole run belongs together even though the first
        // and last are 45s apart.
        let records = (0..<10).map { record(id: "\($0)", secondsFromEpoch: Double($0) * 5) }

        let buckets = PhotoGrouping.candidateBuckets(for: records)

        #expect(buckets.count == 1)
        #expect(buckets[0].count == 10)
    }

    @Test("Different shapes in the same moment are separated")
    func aspectRatioSplitsBuckets() {
        let records = [
            record(id: "landscape1", secondsFromEpoch: 0, width: 4000, height: 3000),
            record(id: "landscape2", secondsFromEpoch: 2, width: 4000, height: 3000),
            record(id: "portrait1", secondsFromEpoch: 3, width: 3000, height: 4000),
            record(id: "portrait2", secondsFromEpoch: 4, width: 3000, height: 4000),
        ]

        let buckets = PhotoGrouping.candidateBuckets(for: records)

        #expect(buckets.count == 2)
        #expect(buckets.allSatisfy { $0.count == 2 })
    }

    @Test("Videos are excluded from similar-photo buckets")
    func videosExcluded() {
        let records = [
            record(id: "v1", secondsFromEpoch: 0, isVideo: true),
            record(id: "v2", secondsFromEpoch: 2, isVideo: true),
        ]

        #expect(PhotoGrouping.candidateBuckets(for: records).isEmpty)
    }

    @Test("Photos with no creation date are dropped rather than lumped together")
    func undatedPhotosDropped() {
        // Treating these as one bucket would reintroduce the O(n squared) blowup the bucketing
        // step exists to avoid.
        let records = [
            record(id: "a", secondsFromEpoch: nil),
            record(id: "b", secondsFromEpoch: nil),
        ]

        #expect(PhotoGrouping.candidateBuckets(for: records).isEmpty)
    }

    // MARK: - Exact duplicates

    @Test("Byte-identical copies group regardless of how far apart they were taken")
    func exactDuplicatesAreGlobal() {
        let captured = Date(timeIntervalSince1970: 0)
        let records = [
            AssetRecord(
                id: "original",
                creationDate: captured,
                modificationDate: nil,
                pixelWidth: 4000,
                pixelHeight: 3000,
                isVideo: false,
                isScreenshot: false,
                isScreenRecording: false,
                duration: 0,
                isFavorite: false,
                hasAdjustments: false,
                byteSize: 2_048
            ),
            AssetRecord(
                id: "redownloaded",
                creationDate: captured,
                modificationDate: nil,
                pixelWidth: 4000,
                pixelHeight: 3000,
                isVideo: false,
                isScreenshot: false,
                isScreenRecording: false,
                duration: 0,
                isFavorite: false,
                hasAdjustments: false,
                byteSize: 2_048
            ),
        ]

        let groups = PhotoGrouping.exactDuplicateGroups(for: records)

        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }

    @Test("Same size but different dimensions is not a duplicate")
    func exactDuplicatesRespectDimensions() {
        let records = [
            record(id: "a", width: 4000, height: 3000, bytes: 2_048),
            record(id: "b", width: 1000, height: 1000, bytes: 2_048),
        ]

        #expect(PhotoGrouping.exactDuplicateGroups(for: records).isEmpty)
    }

    @Test("Records with unknown size are skipped")
    func exactDuplicatesSkipUnsized() {
        let records = [
            record(id: "a", bytes: nil),
            record(id: "b", bytes: nil),
        ]

        #expect(PhotoGrouping.exactDuplicateGroups(for: records).isEmpty)
    }

    // MARK: - Best-of-group

    @Test("A favourite always wins")
    func favouriteWins() {
        let group = [
            record(id: "sharp", width: 8000, height: 6000),
            record(id: "loved", width: 100, height: 75, isFavorite: true),
        ]

        // Even though it's far lower resolution, the user already told us this one matters.
        let best = PhotoGrouping.bestAssetID(
            in: group,
            aestheticScores: ["sharp": 0.9, "loved": 0.1]
        )

        #expect(best == "loved")
    }

    @Test("Higher aesthetics score wins when neither is a favourite")
    func aestheticsWins() {
        let group = [record(id: "dull"), record(id: "striking")]

        let best = PhotoGrouping.bestAssetID(
            in: group,
            aestheticScores: ["dull": 0.2, "striking": 0.8]
        )

        #expect(best == "striking")
    }

    @Test("A scored photo beats an unscored one")
    func scoredBeatsUnscored() {
        let group = [record(id: "scored"), record(id: "unscored")]

        let best = PhotoGrouping.bestAssetID(in: group, aestheticScores: ["scored": 0.1])

        #expect(best == "scored")
    }

    @Test("Resolution breaks ties when no scores exist")
    func resolutionBreaksTies() {
        let group = [
            record(id: "small", width: 1000, height: 750),
            record(id: "large", width: 4000, height: 3000),
        ]

        let best = PhotoGrouping.bestAssetID(in: group, aestheticScores: [:])

        #expect(best == "large")
    }

    // MARK: - Group assembly

    @Test("Assembled groups nominate a keeper and price the rest")
    func assembleGroupsComputesReclaimable() {
        let bucket = [
            record(id: "a", bytes: 1_000),
            record(id: "b", bytes: 2_000),
            record(id: "c", bytes: 3_000),
        ]

        let groups = PhotoGrouping.assembleGroups(
            bucket: bucket,
            matchedPairs: [(0, 1), (1, 2)],
            aestheticScores: ["a": 0.9, "b": 0.1, "c": 0.1]
        )

        #expect(groups.count == 1)
        let group = try! #require(groups.first)
        #expect(group.bestAssetID == "a")
        // Everything except the keeper: 2000 + 3000.
        #expect(group.reclaimableBytes == 5_000)
        #expect(group.others.count == 2)
    }

    @Test("No matches means no groups")
    func noMatchesNoGroups() {
        let bucket = [record(id: "a"), record(id: "b")]

        #expect(
            PhotoGrouping.assembleGroups(
                bucket: bucket,
                matchedPairs: [],
                aestheticScores: [:]
            ).isEmpty
        )
    }
}
