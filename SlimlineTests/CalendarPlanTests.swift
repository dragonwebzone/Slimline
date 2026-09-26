import Foundation
import Testing

@testable import MyApp

/// Tests that calendar events move through the plan like everything else.
///
/// The risk here is the review screen and the deletion disagreeing — an event counted but not
/// deleted, or deleted without being counted — so these check that events are part of every
/// total and every reset.
@MainActor
@Suite("Calendar events in the plan")
struct CalendarPlanTests {

    @Test("Selected events count towards the total the confirm button shows")
    func eventsCountInTotal() {
        let plan = CleanPlan()

        plan.selectEvents(["e1", "e2"])

        #expect(plan.totalItemCount == 2)
        #expect(plan.isEmpty == false)
    }

    @Test("A plan holding only events is not empty")
    func eventsAloneAreWork() {
        // Otherwise the review bar would never appear for a calendar-only clean.
        let plan = CleanPlan()
        plan.toggleEvent("e1")

        #expect(plan.isEmpty == false)
    }

    @Test("Toggle round-trips")
    func toggleRoundTrips() {
        let plan = CleanPlan()

        plan.toggleEvent("e1")
        #expect(plan.isEventSelected("e1"))

        plan.toggleEvent("e1")
        #expect(plan.isEventSelected("e1") == false)
    }

    @Test("Reset clears events")
    func resetClearsEvents() {
        let plan = CleanPlan()
        plan.selectEvents(["e1"])

        plan.reset()

        #expect(plan.isEmpty)
    }

    @Test("A rescan forgets events that are no longer offered")
    func pruneDropsVanished() {
        // An event deleted on another device, or edited to recur, must not stay selected.
        let plan = CleanPlan()
        plan.selectEvents(["e1", "e2", "e3"])

        plan.pruneEvents(keeping: ["e2"])

        #expect(plan.selectedEventIDs == ["e2"])
    }

    @Test("Deselecting a year leaves other years alone")
    func deselectIsScoped() {
        let plan = CleanPlan()
        plan.selectEvents(["2019-a", "2019-b", "2020-a"])

        plan.deselectEvents(["2019-a", "2019-b"])

        #expect(plan.selectedEventIDs == ["2020-a"])
    }
}
