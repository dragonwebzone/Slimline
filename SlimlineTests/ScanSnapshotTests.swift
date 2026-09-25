import Foundation
import Testing

@testable import MyApp

/// Tests for the fingerprint that decides whether a bucket can be reused.
///
/// This is the whole basis of the incremental scan: if a fingerprint collides when it shouldn't,
/// the app silently serves stale groups and never notices a new photo. If it differs when it
/// shouldn't, every launch rescans the library and the feature buys nothing.
@Suite("Scan snapshot reuse")
struct ScanSnapshotTests {

    private func record(
        id: String,
        modified: TimeInterval? = 0
    ) -> AssetRecord {
        AssetRecord(
            id: id,
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: modified.map { Date(timeIntervalSince1970: $0) },
            pixelWidth: 4000,
            pixelHeight: 3000,
            isVideo: false,
            isScreenshot: false,
            isScreenRecording: false,
            duration: 0,
            isFavorite: false,
            hasAdjustments: false,
            byteSize: 1_000
        )
    }

    @Test("The same bucket fingerprints the same way twice")
    func keyIsStable() {
        let bucket = [record(id: "a"), record(id: "b"), record(id: "c")]

        #expect(ScanSnapshot.bucketKey(for: bucket) == ScanSnapshot.bucketKey(for: bucket))
    }

    @Test("Member order doesn't affect the fingerprint")
    func keyIgnoresOrder() {
        let forwards = [record(id: "a"), record(id: "b"), record(id: "c")]
        let backwards = [record(id: "c"), record(id: "b"), record(id: "a")]

        #expect(ScanSnapshot.bucketKey(for: forwards) == ScanSnapshot.bucketKey(for: backwards))
    }

    @Test("Adding a photo to a bucket changes its fingerprint")
    func newMemberInvalidates() {
        let before = [record(id: "a"), record(id: "b")]
        let after = before + [record(id: "c")]

        #expect(ScanSnapshot.bucketKey(for: before) != ScanSnapshot.bucketKey(for: after))
    }

    @Test("Removing a photo from a bucket changes its fingerprint")
    func removedMemberInvalidates() {
        let before = [record(id: "a"), record(id: "b"), record(id: "c")]
        let after = [record(id: "a"), record(id: "b")]

        #expect(ScanSnapshot.bucketKey(for: before) != ScanSnapshot.bucketKey(for: after))
    }

    @Test("Editing a photo invalidates the bucket it sits in")
    func editedMemberInvalidates() {
        // Same identifiers, same count — only the modification stamp moved. Without stamping,
        // an edited photo would keep its old grouping forever.
        let before = [record(id: "a", modified: 0), record(id: "b", modified: 0)]
        let after = [record(id: "a", modified: 500), record(id: "b", modified: 0)]

        #expect(ScanSnapshot.bucketKey(for: before) != ScanSnapshot.bucketKey(for: after))
    }

    @Test("A photo with no modification date still fingerprints")
    func undatedMemberIsHandled() {
        let bucket = [record(id: "a", modified: nil), record(id: "b")]

        #expect(!ScanSnapshot.bucketKey(for: bucket).isEmpty)
    }

    @Test("Different buckets get different fingerprints")
    func distinctBucketsDiffer() {
        let one = [record(id: "a"), record(id: "b")]
        let two = [record(id: "c"), record(id: "d")]

        #expect(ScanSnapshot.bucketKey(for: one) != ScanSnapshot.bucketKey(for: two))
    }

    @Test("Identifiers that concatenate alike don't collide")
    func separatorPreventsCollisions() {
        // "ab" + "c" and "a" + "bc" must not fingerprint the same, which is what the separator
        // in the key is there to guarantee.
        let one = [record(id: "ab"), record(id: "c")]
        let two = [record(id: "a"), record(id: "bc")]

        #expect(ScanSnapshot.bucketKey(for: one) != ScanSnapshot.bucketKey(for: two))
    }

    @Test("An empty bucket produces a usable key rather than crashing")
    func emptyBucketIsSafe() {
        #expect(!ScanSnapshot.bucketKey(for: []).isEmpty)
    }
}
