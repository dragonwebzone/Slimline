import EventKit
import Foundation

/// A small, `Sendable` snapshot of one calendar event.
///
/// Same pattern as `AssetRecord` and `ContactRecord`: the real `EKEvent` is re-fetched by
/// identifier at deletion time, so a stale record can never remove the wrong event.
nonisolated struct EventRecord: Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let location: String?
}

/// Finds old events that are candidates for clearing.
///
/// Deliberately conservative, because unlike photos there is no Recently Deleted for calendar
/// events, and the deletion syncs to every device on the account:
///
/// - **Only events that ended more than a year ago.** Nothing recent, nothing upcoming.
/// - **No recurring events.** Deleting one 2023 occurrence of a weekly meeting isn't cleanup, and
///   deleting the series would remove future occurrences too.
/// - **Only calendars the user can edit.** Holidays, birthdays and subscribed calendars are
///   read-only; offering them would be offering deletions iOS will refuse.
actor CalendarScanner {
    /// How far back to look. EventKit caps a single predicate at four years, so the span is
    /// walked in chunks.
    private let lookback: TimeInterval = 10 * 365 * 24 * 3600
    private let chunk: TimeInterval = 3 * 365 * 24 * 3600

    /// Events must have ended before this long ago.
    nonisolated static let minimumAge: TimeInterval = 365 * 24 * 3600

    func scan(now: Date = .now) -> [EventRecord] {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).filter(\.allowsContentModifications)
        guard !calendars.isEmpty else { return [] }

        let cutoff = now.addingTimeInterval(-Self.minimumAge)
        var from = now.addingTimeInterval(-lookback)
        var records: [String: EventRecord] = [:]

        while from < cutoff {
            let to = min(from.addingTimeInterval(chunk), cutoff)
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)

            for event in store.events(matching: predicate) where Self.isCandidate(event, cutoff: cutoff) {
                guard let id = event.eventIdentifier else { continue }
                records[id] = EventRecord(
                    id: id,
                    title: event.title?.isEmpty == false ? event.title : "Untitled event",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title,
                    location: event.location?.isEmpty == false ? event.location : nil
                )
            }
            from = to
        }

        // Oldest first: the further back an event is, the less likely anyone needs it.
        return records.values.sorted { $0.start < $1.start }
    }

    private static func isCandidate(_ event: EKEvent, cutoff: Date) -> Bool {
        !event.hasRecurrenceRules
            && event.endDate < cutoff
            && event.calendar.allowsContentModifications
    }
}
