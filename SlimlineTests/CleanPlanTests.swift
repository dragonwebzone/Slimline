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

    @Test("The suggested best shot can be selected like any other photo")
    func bestShotIsSelectable() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [group])

        // A suggestion, not a lock: the user may prefer to keep a different frame.
        #expect(plan.canSelect("a"))
        #expect(plan.select(record(id: "a")))
        #expect(plan.isSelected("a"))
    }

    @Test("Select extras leaves the best shot behind")
    func selectExtrasSparesBestShot() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [group])

        plan.selectExtras(in: group)

        #expect(plan.isSelected("a") == false)
        #expect(plan.isSelected("b"))
        #expect(plan.isSelected("c"))
        #expect(plan.totalAssetCount == 2)
    }

    @Test("Select extras replaces a hand-picked best shot rather than failing on the last extra")
    func selectExtrasDeselectsBestShot() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [group])
        #expect(plan.select(record(id: "a")))

        plan.selectExtras(in: group)

        #expect(plan.isSelected("a") == false)
        #expect(plan.isSelected("b"))
        #expect(plan.isSelected("c"))
    }

    @Test("A whole set can be selected, and is reported as such")
    func wholeSetCanBeSelected() {
        let plan = CleanPlan()
        let other = group(id: "h", memberIDs: ["d", "e"], keeper: "d")
        let set = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [set, other])

        plan.selectAll(in: set)
        #expect(plan.totalAssetCount == 3)
        // The review screen warns from this, so it must count whole sets only.
        #expect(plan.fullySelectedGroupCount == 1)

        #expect(plan.select(record(id: "e")))
        #expect(plan.fullySelectedGroupCount == 1)

        plan.deselectAll(in: set)
        #expect(plan.fullySelectedGroupCount == 0)
    }

    @Test("Select extras after select all leaves just the best shot kept")
    func selectExtrasAfterSelectAll() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], keeper: "a")
        plan.register(groups: [group])

        plan.selectAll(in: group)
        plan.selectExtras(in: group)

        #expect(plan.isSelected("a") == false)
        #expect(plan.fullySelectedGroupCount == 0)
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

/// The same safety rules, for contacts.
///
/// These matter more than the photo equivalents: a deleted photo sits in Recently Deleted for 30
/// days, but a deleted contact is gone immediately and for good.
@MainActor
@Suite("Clean plan contact safety")
struct CleanPlanContactTests {

    private func contact(id: String, fields: Int = 0) -> ContactRecord {
        ContactRecord(
            id: id,
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: (0..<fields).map { "900000000\($0)" }
        )
    }

    private func group(
        id: String,
        memberIDs: [String],
        primary: String
    ) -> DuplicateContactGroup {
        DuplicateContactGroup(
            id: id,
            contacts: memberIDs.map { contact(id: $0) },
            primaryContactID: primary
        )
    }

    @Test("The primary card can never be selected for deletion")
    func primaryIsProtected() {
        let plan = CleanPlan()
        plan.register(contactGroups: [group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")])

        #expect(plan.isContactProtected("a"))
        #expect(plan.canSelectContact("a") == false)
        #expect(plan.selectContact("a") == false)
        #expect(plan.isContactSelected("a") == false)
    }

    @Test("A contact group can never be emptied completely")
    func groupIsNeverEmptied() {
        let plan = CleanPlan()
        // Primary protection is sidestepped by naming a primary outside the group, so the
        // never-empty rule is what's under test.
        plan.register(contactGroups: [
            DuplicateContactGroup(
                id: "g",
                contacts: [contact(id: "a"), contact(id: "b")],
                primaryContactID: "elsewhere"
            )
        ])

        #expect(plan.selectContact("a"))
        #expect(plan.canSelectContact("b") == false)
        #expect(plan.selectContact("b") == false)
        #expect(plan.selectedContactIDs.count == 1)
    }

    @Test("A rescan drops a selection that has become the primary")
    func rescanClearsNewlyProtectedContact() {
        let plan = CleanPlan()
        plan.register(contactGroups: [group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")])

        #expect(plan.selectContact("b"))

        // A rescan promotes "b" to the card we now recommend keeping.
        plan.register(contactGroups: [group(id: "g", memberIDs: ["a", "b", "c"], primary: "b")])

        #expect(plan.isContactSelected("b") == false)
        #expect(plan.selectedContactIDs.isEmpty)
    }

    @Test("A rescan forgets contacts whose group has gone")
    func rescanDropsVanishedContacts() {
        let plan = CleanPlan()
        plan.register(contactGroups: [group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")])
        #expect(plan.selectContact("b"))

        // The duplicates were resolved elsewhere, so the group no longer exists. A selection that
        // outlived its group would be deleting something we can no longer describe.
        plan.register(contactGroups: [])

        #expect(plan.selectedContactIDs.isEmpty)
        #expect(plan.mergingGroupIDs.isEmpty)
    }

    @Test("Marking a group to merge clears its individual deletions")
    func mergeSupersedesSelections() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")
        plan.register(contactGroups: [group])

        #expect(plan.selectContact("b"))
        plan.toggleMerge(group)

        // Otherwise the review screen would count "b" twice, and the merge would be reading a
        // card the deletion had already removed.
        #expect(plan.isMerging("g"))
        #expect(plan.isContactSelected("b") == false)
        #expect(plan.canSelectContact("b") == false)
    }

    @Test("Undoing a merge makes the group selectable again")
    func unmergeRestoresSelection() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")
        plan.register(contactGroups: [group])

        plan.toggleMerge(group)
        plan.toggleMerge(group)

        #expect(plan.isMerging("g") == false)
        #expect(plan.canSelectContact("b"))
    }

    @Test("Delete the others queues every card but the kept one")
    func deleteOthersSparesKeeper() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")
        plan.register(contactGroups: [group])

        plan.toggleDeleteOthers(group)

        #expect(plan.isDeletingOthers(group))
        #expect(plan.selectedContactIDs == ["b", "c"])
        #expect(plan.isContactSelected("a") == false)

        plan.toggleDeleteOthers(group)
        #expect(plan.isDeletingOthers(group) == false)
        #expect(plan.selectedContactIDs.isEmpty)
    }

    @Test("Merge and delete the others replace each other")
    func mergeAndDeleteAreExclusive() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")
        plan.register(contactGroups: [group])

        plan.toggleMerge(group)
        plan.toggleDeleteOthers(group)
        #expect(plan.isMerging("g") == false)
        #expect(plan.isDeletingOthers(group))
        #expect(plan.totalContactsRemoved == 2)

        plan.toggleMerge(group)
        #expect(plan.isMerging("g"))
        #expect(plan.isDeletingOthers(group) == false)
        #expect(plan.totalContactsRemoved == 2)
    }

    @Test("Totals count merged and deleted contacts without double counting")
    func totalsCountEachContactOnce() {
        let plan = CleanPlan()
        let merging = group(id: "g1", memberIDs: ["a", "b", "c"], primary: "a")
        let other = group(id: "g2", memberIDs: ["d", "e"], primary: "d")
        plan.register(contactGroups: [merging, other])

        plan.toggleMerge(merging)   // removes "b" and "c"
        #expect(plan.selectContact("e"))

        #expect(plan.contactsRemovedByMerges == 2)
        #expect(plan.selectedContactIDs.count == 1)
        #expect(plan.totalContactsRemoved == 3)
    }

    @Test("A plan holding only a merge is not empty")
    func mergeAloneCountsAsWork() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b"], primary: "a")
        plan.register(contactGroups: [group])

        plan.toggleMerge(group)

        // The review button hides on `isEmpty`, so a merge-only plan must not look like nothing.
        #expect(plan.isEmpty == false)
        #expect(plan.mergingGroups.count == 1)
    }

    @Test("Reset clears merges as well as selections")
    func resetClearsMerges() {
        let plan = CleanPlan()
        let group = group(id: "g", memberIDs: ["a", "b", "c"], primary: "a")
        plan.register(contactGroups: [group])

        plan.toggleMerge(group)
        plan.selectContact("b")
        plan.reset()

        #expect(plan.isEmpty)
        #expect(plan.mergingGroupIDs.isEmpty)
    }

    @Test("An ungrouped contact has no grouping constraint")
    func ungroupedContactsSelectFreely() {
        let plan = CleanPlan()

        // Nothing registered, so there's no group to protect or empty.
        #expect(plan.selectContact("loose"))
        #expect(plan.isContactSelected("loose"))
    }
}
