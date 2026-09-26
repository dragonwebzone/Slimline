import Foundation

/// A running total of everything Slimline has cleared, across every session.
///
/// Recorded from what a clean actually did — the deletion outcome — never from what was selected,
/// so a declined system prompt or a half-failed clean can't inflate it. Stored locally in
/// `UserDefaults`; it's a pair of counters and means nothing off the device.
@Observable
final class CleanupHistory {
    private let defaults: UserDefaults
    private let bytesKey = "slimline.history.bytes"
    private let itemsKey = "slimline.history.items"
    private let cleansKey = "slimline.history.cleans"

    private(set) var bytes: Int64
    private(set) var items: Int
    private(set) var cleans: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bytes = Int64(defaults.integer(forKey: bytesKey))
        items = defaults.integer(forKey: itemsKey)
        cleans = defaults.integer(forKey: cleansKey)
    }

    /// Adds one clean's result. A clean that did nothing leaves the history untouched, so
    /// "3 cleans" never counts the time the user cancelled at the system prompt.
    func record(_ outcome: DeletionService.Outcome) {
        let removed = outcome.assetsDeleted + outcome.contactsDeleted + outcome.contactsMerged
            + outcome.eventsDeleted
        guard removed > 0 || outcome.bytesPendingReclaim > 0 else { return }

        bytes += outcome.bytesPendingReclaim
        items += removed
        cleans += 1

        defaults.set(Int(bytes), forKey: bytesKey)
        defaults.set(items, forKey: itemsKey)
        defaults.set(cleans, forKey: cleansKey)
    }
}
