import Foundation

/// The keepers the user chose themselves, remembered across rescans and relaunches.
///
/// Without this, tapping a star was undone by the next scan: the scanner re-derives its own pick
/// every time, so the user's decision lasted only until pull-to-refresh or a relaunch. That's the
/// app quietly overruling someone about their own photos, twice.
///
/// Kept apart from `ScanSnapshot` deliberately. A forced rescan throws the snapshot away to
/// re-derive everything, and that must not throw away decisions the user made. Stored as plain
/// identifiers in `UserDefaults` — they never leave the device and mean nothing outside it.
///
/// Keyed by asset rather than by group. Groups are re-derived on every scan and can merge or split
/// as photos are added, so "the keeper of group X" has no stable meaning; "the user wants to keep
/// this photo" does.
final class KeeperPreferences {
    private let defaults: UserDefaults
    private let photoKey = "slimline.preferredPhotoKeepers"
    private let contactKey = "slimline.preferredContactPrimaries"

    private(set) var photos: Set<String>
    private(set) var contacts: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        photos = Set(defaults.stringArray(forKey: photoKey) ?? [])
        contacts = Set(defaults.stringArray(forKey: contactKey) ?? [])
    }

    /// Records a choice, and forgets any earlier preference among the same set.
    ///
    /// Otherwise choosing B after A would leave both remembered, and the next scan would have to
    /// guess which one the user meant.
    func preferPhoto(_ id: String, over group: [String]) {
        photos.subtract(group)
        photos.insert(id)
        defaults.set(Array(photos), forKey: photoKey)
    }

    func preferContact(_ id: String, over group: [String]) {
        contacts.subtract(group)
        contacts.insert(id)
        defaults.set(Array(contacts), forKey: contactKey)
    }

    /// Drops preferences for photos that no longer exist, so the list can't grow without bound.
    func prunePhotos(keeping live: Set<String>) {
        let pruned = photos.intersection(live)
        guard pruned.count != photos.count else { return }
        photos = pruned
        defaults.set(Array(photos), forKey: photoKey)
    }

    // MARK: - Applying

    /// Moves each group's keeper to the user's choice, where they made one.
    ///
    /// Pure and static so the rule can be tested without a photo library.
    static func applying(
        _ preferred: Set<String>,
        to groups: [SimilarPhotoGroup]
    ) -> [SimilarPhotoGroup] {
        groups.map { group in
            guard let chosen = group.assets.first(where: { preferred.contains($0.id) }),
                  chosen.id != group.bestAssetID
            else { return group }

            return SimilarPhotoGroup(
                id: group.id,
                assets: ScanCoordinator.ordered(group.assets, keeper: chosen.id),
                bestAssetID: chosen.id,
                similarity: group.similarity
            )
        }
    }

    static func applying(
        _ preferred: Set<String>,
        to groups: [DuplicateContactGroup]
    ) -> [DuplicateContactGroup] {
        groups.map { group in
            guard let chosen = group.contacts.first(where: { preferred.contains($0.id) }),
                  chosen.id != group.primaryContactID
            else { return group }

            return DuplicateContactGroup(
                id: group.id,
                contacts: group.contacts,
                primaryContactID: chosen.id
            )
        }
    }
}
