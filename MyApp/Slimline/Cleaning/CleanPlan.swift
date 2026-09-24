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

    /// Assets we refuse to select: the suggested keeper in each similar-photo group.
    private var protectedAssetIDs: Set<String> = []

    /// Asset identifier to the group it belongs to, for the "never empty a group" rule.
    private var groupByAsset: [String: String] = [:]
    private var assetsByGroup: [String: Set<String>] = [:]

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
        selectedAssets.isEmpty && selectedContactIDs.isEmpty
    }

    var selectedAssetIDs: [String] {
        Array(selectedAssets.keys)
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

    func toggleContact(_ identifier: String) {
        if selectedContactIDs.contains(identifier) {
            selectedContactIDs.remove(identifier)
        } else {
            selectedContactIDs.insert(identifier)
        }
    }

    /// Clears everything. Called after a successful clean.
    func reset() {
        selectedAssets.removeAll()
        selectedContactIDs.removeAll()
    }

    /// Forgets selections for assets that no longer exist.
    func pruneMissing(liveAssetIDs: Set<String>) {
        selectedAssets = selectedAssets.filter { liveAssetIDs.contains($0.key) }
    }
}
