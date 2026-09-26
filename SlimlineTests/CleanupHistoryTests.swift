import Foundation
import Testing

@testable import MyApp

/// Tests for the running "cleared so far" total.
///
/// The number is only worth showing if it's true, so these check it counts what a clean actually
/// did rather than what was selected, and that failed or declined cleans leave it alone.
@MainActor
@Suite("Cleanup history")
struct CleanupHistoryTests {

    private func freshDefaults() -> UserDefaults {
        let name = "slimline-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A successful clean adds to the total")
    func successAccumulates() {
        let history = CleanupHistory(defaults: freshDefaults())

        history.record(.init(assetsRequested: 3, assetsDeleted: 3, bytesPendingReclaim: 3_000))
        history.record(.init(assetsRequested: 2, assetsDeleted: 2, bytesPendingReclaim: 2_000))

        #expect(history.bytes == 5_000)
        #expect(history.items == 5)
        #expect(history.cleans == 2)
    }

    @Test("A declined clean changes nothing")
    func declinedIsIgnored() {
        // The user tapped "Don't Allow" on the system prompt: nothing was removed, so nothing
        // should be claimed.
        let history = CleanupHistory(defaults: freshDefaults())

        history.record(.init(assetsRequested: 5, failure: "Nothing was deleted."))

        #expect(history.bytes == 0)
        #expect(history.cleans == 0)
    }

    @Test("Only what was actually deleted counts, not what was requested")
    func partialCountsDeletedOnly() {
        let history = CleanupHistory(defaults: freshDefaults())

        history.record(.init(assetsRequested: 10, assetsDeleted: 4, bytesPendingReclaim: 4_000))

        #expect(history.items == 4)
        #expect(history.bytes == 4_000)
    }

    @Test("Contact merges count as cleans even though they free no space")
    func contactsCount() {
        let history = CleanupHistory(defaults: freshDefaults())

        history.record(.init(contactsDeleted: 1, contactsMerged: 2))

        #expect(history.items == 3)
        #expect(history.bytes == 0)
        #expect(history.cleans == 1)
    }

    @Test("The total survives a relaunch")
    func persists() {
        let defaults = freshDefaults()
        CleanupHistory(defaults: defaults)
            .record(.init(assetsRequested: 1, assetsDeleted: 1, bytesPendingReclaim: 7_000))

        let reopened = CleanupHistory(defaults: defaults)

        #expect(reopened.bytes == 7_000)
        #expect(reopened.cleans == 1)
    }
}
