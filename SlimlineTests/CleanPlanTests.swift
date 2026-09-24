import Foundation
import Testing

@testable import MyApp

/// Tests for the selection safety rules.
///
/// These encode the brief's hardest requirement — nothing is removed without approval, and a
/// group can never be wiped out entirely. They live in the model rather than the UI precisely so
/// they can be asserted here.
@MainActor
@Suite("Clean plan safety")
struct CleanPlanTests {

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

    private func group(id: String, memberIDs: [String], keeper: String) -> SimilarPhotoGroup {
        SimilarPhotoGroup(
            id: id,
            assets: memberIDs.map { record(id: $0) },
            bestAssetID: keeper
        )
    }

    @Test("The keeper in a group can never be selected")
    func keeperIsProtected() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [group])

        #expect(plan.isProtected("a"))
        #expect(plan.canSelect("a") == false)
        #expect(plan.select(record(id: "a")) == false)
        #expect(plan.isSelected("a") == false)
    }

    @Test("Select extras leaves the keeper behind")
    func selectExtrasSparesKeeper() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [group])

        plan.selectExtras(in: group)

        #expect(plan.isSelected("a") == false)
        #expect(plan.isSelected("b"))
        #expect(plan.isSelected("c"))
        #expect(plan.totalAssetCount == 2)
    }

    @Test("A group can never have every member selected")
    func groupIsNeverEmptied() {
        let plan = CleanPlan()
        // Keeper protection is relaxed here by naming a keeper outside the group, so the
        // never-empty rule is what's actually under test.
        let group = SimilarPhotoGroup(
            id: "g",
            assets: [record(id: "a"), record(id: "b")],
            bestAssetID: "elsewhere"
        )
        plan.register(groups: [group])

        #expect(plan.select(record(id: "a")))
        // Selecting the second would leave nothing kept.
        #expect(plan.canSelect("b") == false)
        #expect(plan.select(record(id: "b")) == false)
        #expect(plan.totalAssetCount == 1)
    }

    @Test("Re-registering drops a selection that has become the keeper")
    func rescanClearsNewlyProtectedSelection() {
        let plan = CleanPlan()
        plan.register(groups: [group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")])

        #expect(plan.select(record(id: "b")))
        #expect(plan.isSelected("b"))

        // A rescan promotes "b" to keeper. Silently deleting what we now call the best shot
        // would be a real bug.
        plan.register(groups: [group(id: "g", memberIDs: ["a", "b", "c"], keeper: "b")])

        #expect(plan.isSelected("b") == false)
        #expect(plan.totalAssetCount == 0)
    }

    @Test("Totals sum the selected bytes")
    func totalsAddUp() {
        let plan = CleanPlan()

        plan.select(record(id: "a", bytes: 1_500))
        plan.select(record(id: "b", bytes: 2_500))

        #expect(plan.totalBytes == 4_000)
        #expect(plan.totalAssetCount == 2)
    }

    @Test("Flat lists have no grouping constraint")
    func flatListsSelectFreely() {
        let plan = CleanPlan()
        let screenshots = (0..<5).map { record(id: "s\($0)") }

        plan.selectAll(screenshots)

        // Screenshots aren't grouped, so selecting every one is legitimate.
        #expect(plan.totalAssetCount == 5)
    }

    @Test("Toggle deselects an already-selected asset")
    func toggleRoundTrips() {
        let plan = CleanPlan()
        let asset = record(id: "a")

        plan.toggle(asset)
        #expect(plan.isSelected("a"))

        plan.toggle(asset)
        #expect(plan.isSelected("a") == false)
    }

    @Test("Reset clears everything")
    func resetClears() {
        let plan = CleanPlan()
        plan.select(record(id: "a"))
        plan.toggleContact("contact-1")

        plan.reset()

        #expect(plan.isEmpty)
    }

    @Test("Pruning forgets assets that no longer exist")
    func pruneDropsMissing() {
        let plan = CleanPlan()
        plan.select(record(id: "a"))
        plan.select(record(id: "b"))

        plan.pruneMissing(liveAssetIDs: ["a"])

        #expect(plan.isSelected("a"))
        #expect(plan.isSelected("b") == false)
    }
}
