import Foundation
import Testing

@testable import MyApp

/// Tests that Similar Sets and Duplicates are two halves of one list, not two views of it.
///
/// Each segment's headline is the sum of its own groups, so if a group could land in both, or
/// neither, the two figures would stop adding up to what the scan actually found.
@Suite("Similar versus duplicate sets")
struct SimilarityPartitionTests {

    private func group(_ id: String, similarity: Double?, bytes: Int64) -> SimilarPhotoGroup {
        let record = { (suffix: String) in
            AssetRecord(
                id: "\(id)-\(suffix)",
                creationDate: nil,
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
        return SimilarPhotoGroup(
            id: id,
            assets: [record("keep"), record("extra")],
            bestAssetID: "\(id)-keep",
            similarity: similarity
        )
    }

    @Test("Every group is in exactly one segment")
    func segmentsPartitionTheGroups() {
        let groups = [
            group("dup", similarity: 0.99, bytes: 5_000),
            group("burst", similarity: 0.90, bytes: 3_000),
            group("edge", similarity: 0.97, bytes: 1_000),
            group("unknown", similarity: nil, bytes: 2_000),
        ]

        let duplicates = groups.filter(\.isDuplicate)
        let similar = groups.filter { !$0.isDuplicate }

        #expect(Set(duplicates.map(\.id)).isDisjoint(with: similar.map(\.id)))
        #expect(duplicates.count + similar.count == groups.count)
    }

    @Test("The two segment totals differ and add up to the whole")
    func totalsAreSeparate() {
        let groups = [
            group("dup", similarity: 0.99, bytes: 5_000),
            group("burst", similarity: 0.90, bytes: 3_000),
        ]

        let duplicateTotal = groups.filter(\.isDuplicate).reduce(0) { $0 + $1.reclaimableBytes }
        let similarTotal = groups.filter { !$0.isDuplicate }.reduce(0) { $0 + $1.reclaimableBytes }
        let whole = groups.reduce(0) { $0 + $1.reclaimableBytes }

        #expect(duplicateTotal == 5_000)
        #expect(similarTotal == 3_000)
        #expect(duplicateTotal + similarTotal == whole)
    }

    @Test("A group with no recorded similarity counts as similar, not duplicate")
    func unknownSimilarityIsNotADuplicate() {
        // Groups restored from an older cache carry no similarity. Calling them duplicates would
        // be a claim the app can't back up.
        #expect(group("old", similarity: nil, bytes: 1).isDuplicate == false)
    }
}
