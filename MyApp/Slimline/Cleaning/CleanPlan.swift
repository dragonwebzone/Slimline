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

    /// Assets we refuse to select: the suggested keeper in each similar-photo group.
    private var protectedAssetIDs: Set<String> = []

    /// Asset identifier to the group it belongs to, for the "never empty a group" rule.
    private var groupByAsset: [String: String] = [:]
    private var assetsByGroup: [String: Set<String>] = [:]

    /// The same three structures for contacts: the primary card in each duplicate group is
    /// protected, and a group can never be emptied completely.
    private var protectedContactIDs: Set<String> = []
    private var groupByContact: [String: String] = [:]
    private var contactsByGroup: [String: Set<String>] = [:]
    private var contactGroupsByID: [String: DuplicateContactGroup] = [:]

    // MARK: - Registration

    /// Teaches the plan about similar-photo groups so it can enforce keeper protection.
    ///
    /// Called whenever a scan completes. Re-registering replaces the previous topology but keeps
    /// any still-valid selections.
    func register(groups: [SimilarPhotoGroup]) {
        protectedAssetIDs.removeAll()
        groupByAsset.removeAll()
        assetsByGroup.removeAll()

        for group in groups {
            protectedAssetIDs.insert(group.bestAssetID)
            let ids = Set(group.assets.map(\.id))
            assetsByGroup[group.id] = ids
            for id in ids {
                groupByAsset[id] = group.id
            }
        }

        // Drop any selection that is now protected — e.g. a rescan promoted a different photo to
        // keeper. Silently deleting something we now call "the best shot" would be a real bug.
        for id in protectedAssetIDs where selectedAssets[id] != nil {
            selectedAssets.removeValue(forKey: id)
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

    func isProtected(_ assetID: String) -> Bool {
        protectedAssetIDs.contains(assetID)
    }

    /// Whether selecting this asset is allowed right now.
    ///
    /// Refuses protected keepers, and refuses the selection that would leave a group with nothing
    /// kept. The second rule is belt-and-braces given keepers are already protected, but it holds
    /// even if keeper protection is ever relaxed.
    func canSelect(_ assetID: String) -> Bool {
        if protectedAssetIDs.contains(assetID) { return false }
        guard let groupID = groupByAsset[assetID], let members = assetsByGroup[groupID] else {
            return true
        }
        let selectedInGroup = members.filter { selectedAssets[$0] != nil }.count
        return selectedInGroup + 1 < members.count
    }

    var totalBytes: Int64 {
        selectedAssets.values.reduce(0, +)
    }

    var totalAssetCount: Int {
        selectedAssets.count
    }

    var isEmpty: Bool {
        selectedAssets.isEmpty && selectedContactIDs.isEmpty && mergingGroupIDs.isEmpty
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

    /// Selects everything in a group except the keeper. Used by "select all extras".
    func selectExtras(in group: SimilarPhotoGroup) {
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

    /// Clears everything. Called after a successful clean.
    func reset() {
        selectedAssets.removeAll()
        selectedContactIDs.removeAll()
        mergingGroupIDs.removeAll()
    }

    /// Forgets selections for assets that no longer exist.
    func pruneMissing(liveAssetIDs: Set<String>) {
        selectedAssets = selectedAssets.filter { liveAssetIDs.contains($0.key) }
    }
}
