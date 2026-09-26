import Foundation

/// Photos and videos the user has decided to keep, and never wants suggested again.
///
/// Different from a keeper star. A star says "of this set, keep this one", and the set is still
/// shown. This says "stop showing me this photo": it's taken out of every result — screenshots,
/// videos, blurry, similar sets — on this scan and every one after it, until the user brings it
/// back from the Kept Photos screen.
///
/// Kept apart from `ScanSnapshot` for the same reason `KeeperPreferences` is: a forced rescan
/// throws the snapshot away, and that must never throw away a decision the user made. Stored as
/// plain identifiers in `UserDefaults`, which never leave the device.
@Observable
final class KeptPhotos {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "slimline.keptPhotos"

    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: key) ?? [])
    }

    var count: Int { ids.count }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func keep(_ newIDs: some Sequence<String>) {
        let updated = ids.union(newIDs)
        guard updated.count != ids.count else { return }
        ids = updated
        save()
    }

    /// Lets photos be suggested again.
    func release(_ released: some Sequence<String>) {
        let updated = ids.subtracting(released)
        guard updated.count != ids.count else { return }
        ids = updated
        save()
    }

    /// Forgets photos that have left the library, so the list can't grow without bound.
    func prune(keeping live: Set<String>) {
        let pruned = ids.intersection(live)
        guard pruned.count != ids.count else { return }
        ids = pruned
        save()
    }

    private func save() {
        defaults.set(Array(ids), forKey: key)
    }
}
