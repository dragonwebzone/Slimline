import Foundation

/// The single source of truth for what the user has chosen to remove.
///
/// Every category screen writes here and the review screen reads only from here, so the number
/// shown before deletion is by construction the same set that gets deleted. The safety rules live
/// in this type rather than in the views: a UI bug then can't produce a selection the model would
/// refuse.
@Observable
final class CleanPlan {
    /// Asset identifier to byte size.
    private(set) var selectedAssets: [String: Int64] = [:]

    /// Contact identifiers marked for deletion (merges are tracked separately, as they're not
    /// simple removals).
    private(set) var selectedContactIDs: Set<String> = []

    /// Duplicate-contact groups marked to be merged into their primary card.
    private(set) var mergingGroupIDs: Set<String> = []

    /// Calendar events marked for deletion. No grouping rules apply: each old event stands alone,
    /// and there's no "keeper" to protect.
    private(set) var selectedEventIDs: Set<String> = []

    /// Asset identifier to the group it belongs to, so the review screen can say when a whole set
    /// is about to go.
    private var groupByAsset: [String: String] = [:]
    private var assetsByGroup: [String: Set<String>] = [:]

    /// The same three structures for contacts: the primary card in each duplicate group is
    /// protected, and a group can never be emptied completely.
    private var protectedContactIDs: Set<String> = []
    private var groupByContact: [String: String] = [:]
    private var contactsByGroup: [String: Set<String>] = [:]
    private var contactGroupsByID: [String: DuplicateContactGroup] = [:]

    // MARK: - Registration

    /// Teaches the plan about similar-photo groups.
    ///
    /// Called whenever a scan completes. Re-registering replaces the previous topology but keeps
    /// any still-valid selections.
    ///
    /// No photo is locked, and a whole set may be selected — to keep it all from the review bar,
    /// or because none of it is wanted. Deleted photos go to Recently Deleted for 30 days, and the
    /// review screen says plainly when an entire set is about to go, so that's never a surprise.
    func register(groups: [SimilarPhotoGroup]) {
        groupByAsset.removeAll()
        assetsByGroup.removeAll()

        for group in groups {
            let ids = Set(group.assets.map(\.id))
            assetsByGroup[group.id] = ids
            for id in ids {
                groupByAsset[id] = group.id
            }
        }
    }

    /// Teaches the plan about duplicate-contact groups, with the same guarantees as photos.
    func register(contactGroups: [DuplicateContactGroup]) {
        protectedContactIDs.removeAll()
        groupByContact.removeAll()
        contactsByGroup.removeAll()
        contactGroupsByID.removeAll()

        for group in contactGroups {
            protectedContactIDs.insert(group.primaryContactID)
            let ids = Set(group.contacts.map(\.id))
            contactsByGroup[group.id] = ids
            contactGroupsByID[group.id] = group
            for id in ids {
                groupByContact[id] = group.id
            }
        }

        // A rescan can promote a different card to primary; drop any selection it just protected.
        selectedContactIDs.subtract(protectedContactIDs)

        // Forget contacts and merges for groups that no longer exist, so a stale selection can't
        // survive into a later clean.
        selectedContactIDs = selectedContactIDs.filter { groupByContact[$0] != nil }
        mergingGroupIDs = mergingGroupIDs.filter { contactGroupsByID[$0] != nil }
    }

    // MARK: - Queries

    func isSelected(_ assetID: String) -> Bool {
        selectedAssets[assetID] != nil
    }

    /// Whether selecting this asset is allowed. Always, now that no photo is locked; kept as the
    /// single place a future rule would go.
    func canSelect(_ assetID: String) -> Bool {
        true
    }

    /// Similar-photo sets with every photo selected — the review screen warns before these go.
    var fullySelectedGroupCount: Int {
        assetsByGroup.values.filter { members in
            !members.isEmpty && members.allSatisfy { selectedAssets[$0] != nil }
        }.count
    }

    /// Selects every photo in a set.
    func selectAll(in group: SimilarPhotoGroup) {
        for record in group.assets {
            select(record)
        }
    }

    var totalBytes: Int64 {
        selectedAssets.values.reduce(0, +)
    }

    var totalAssetCount: Int {
        selectedAssets.count
    }

    var isEmpty: Bool {
        selectedAssets.isEmpty && selectedContactIDs.isEmpty && mergingGroupIDs.isEmpty
            && selectedEventIDs.isEmpty
    }

    /// Every item this plan will remove, of every kind — what the review bar and the confirm
    /// button count. Kept here so the two can't disagree.
    var totalItemCount: Int {
        totalAssetCount + totalContactsRemoved + selectedEventIDs.count
    }

    var selectedAssetIDs: [String] {
        Array(selectedAssets.keys)
    }

    // MARK: - Contact queries

    func isContactSelected(_ identifier: String) -> Bool {
        selectedContactIDs.contains(identifier)
    }

    func isContactProtected(_ identifier: String) -> Bool {
        protectedContactIDs.contains(identifier)
    }

    /// Whether deleting this contact is allowed right now.
    ///
    /// Refuses the primary card, refuses the selection that would leave a group with nothing, and
    /// refuses any card in a group already marked for merging — the merge decides that group's
    /// fate, and letting both act on it would delete a card the merge still needs to read.
    func canSelectContact(_ identifier: String) -> Bool {
        if protectedContactIDs.contains(identifier) { return false }
        guard let groupID = groupByContact[identifier],
              let members = contactsByGroup[groupID]
        else { return true }

        if mergingGroupIDs.contains(groupID) { return false }

        let selectedInGroup = members.filter { selectedContactIDs.contains($0) }.count
        return selectedInGroup + 1 < members.count
    }

    func isMerging(_ groupID: String) -> Bool {
        mergingGroupIDs.contains(groupID)
    }

    /// Groups the user has approved merging, resolved back to their records.
    var mergingGroups: [DuplicateContactGroup] {
        mergingGroupIDs.compactMap { contactGroupsByID[$0] }
    }

    /// Contacts that a merge will remove, over and above those selected outright.
    var contactsRemovedByMerges: Int {
        mergingGroups.reduce(0) { $0 + $1.duplicates.count }
    }

    /// Every contact this plan will remove, whether by merge or by outright deletion.
    var totalContactsRemoved: Int {
        selectedContactIDs.count + contactsRemovedByMerges
    }

    // MARK: - Mutation

    @discardableResult
    func select(_ record: AssetRecord) -> Bool {
        guard canSelect(record.id) else { return false }
        selectedAssets[record.id] = record.byteSize ?? 0
        return true
    }

    func deselect(_ assetID: String) {
        selectedAssets.removeValue(forKey: assetID)
    }

    @discardableResult
    func toggle(_ record: AssetRecord) -> Bool {
        if isSelected(record.id) {
            deselect(record.id)
            return true
        }
        return select(record)
    }

    /// Selects everything in a group except the suggested best shot. Used by "select extras".
    ///
    /// The best shot is deselected too, if the user had picked it: "select extras" means "keep the
    /// best one", and leaving it selected would have the plan refuse the last extra instead.
    func selectExtras(in group: SimilarPhotoGroup) {
        deselect(group.bestAssetID)
        for record in group.others {
            select(record)
        }
    }

    func deselectAll(in group: SimilarPhotoGroup) {
        for record in group.assets {
            deselect(record.id)
        }
    }

    func selectAll(_ records: [AssetRecord]) {
        for record in records {
            select(record)
        }
    }

    func deselectAll(_ records: [AssetRecord]) {
        for record in records {
            deselect(record.id)
        }
    }

    @discardableResult
    func selectContact(_ identifier: String) -> Bool {
        guard canSelectContact(identifier) else { return false }
        selectedContactIDs.insert(identifier)
        return true
    }

    func deselectContact(_ identifier: String) {
        selectedContactIDs.remove(identifier)
    }

    @discardableResult
    func toggleContact(_ identifier: String) -> Bool {
        if selectedContactIDs.contains(identifier) {
            deselectContact(identifier)
            return true
        }
        return selectContact(identifier)
    }

    /// Marks a group to be merged into its primary card, or unmarks it.
    ///
    /// Merging supersedes individual deletions in that group, so those selections are cleared —
    /// otherwise the review screen would count the same contact twice.
    func toggleMerge(_ group: DuplicateContactGroup) {
        if mergingGroupIDs.contains(group.id) {
            mergingGroupIDs.remove(group.id)
        } else {
            mergingGroupIDs.insert(group.id)
            selectedContactIDs.subtract(group.contacts.map(\.id))
        }
    }

    /// Whether every card except the kept one is queued for outright deletion.
    func isDeletingOthers(_ group: DuplicateContactGroup) -> Bool {
        !group.duplicates.isEmpty && group.duplicates.allSatisfy { selectedContactIDs.contains($0.id) }
    }

    /// Queues every card except the kept one for deletion, or takes them all back.
    ///
    /// The alternative to merging, so it replaces a merge on the same group rather than stacking
    /// with it. The kept card is never included, so the group can't be emptied.
    func toggleDeleteOthers(_ group: DuplicateContactGroup) {
        let others = group.duplicates.map(\.id).filter { !protectedContactIDs.contains($0) }
        if isDeletingOthers(group) {
            selectedContactIDs.subtract(others)
        } else {
            mergingGroupIDs.remove(group.id)
            selectedContactIDs.formUnion(others)
        }
    }

    /// Clears everything. Called after a successful clean.
    // MARK: - Calendar events

    func isEventSelected(_ id: String) -> Bool {
        selectedEventIDs.contains(id)
    }

    func toggleEvent(_ id: String) {
        if selectedEventIDs.contains(id) {
            selectedEventIDs.remove(id)
        } else {
            selectedEventIDs.insert(id)
        }
    }

    func selectEvents(_ ids: [String]) {
        selectedEventIDs.formUnion(ids)
    }

    func deselectEvents(_ ids: [String]) {
        selectedEventIDs.subtract(ids)
    }

    /// Forgets selections for events that are no longer candidates — deleted elsewhere, or edited
    /// into something the scan no longer offers.
    func pruneEvents(keeping live: Set<String>) {
        selectedEventIDs.formIntersection(live)
    }

    func reset() {
        selectedAssets.removeAll()
        selectedContactIDs.removeAll()
        mergingGroupIDs.removeAll()
        selectedEventIDs.removeAll()
    }

    /// Forgets selections for assets that no longer exist.
    func pruneMissing(liveAssetIDs: Set<String>) {
        selectedAssets = selectedAssets.filter { liveAssetIDs.contains($0.key) }
    }
}
