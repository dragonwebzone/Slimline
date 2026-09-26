import SwiftUI

/// Old calendar events, grouped by year, for bulk clearing.
///
/// Calendar events take up no meaningful storage, so this is tidying rather than space-saving, and
/// the screen says so rather than inventing a byte figure. What it offers is the long tail of
/// one-off events — dentist appointments from 2019, a flight from three years ago — that clutters
/// search and the calendar's list view.
struct CalendarCleanupView: View {
    let events: [EventRecord]
    let phase: ScanCoordinator.ContactPhase
    let access: CalendarAccess
    let plan: CleanPlan
    let onRequestAccess: () async -> Void
    let onOpenSettings: () -> Void
    let onScan: () -> Void

    var body: some View {
        Group {
            if access.canScan {
                content
            } else {
                gate
            }
        }
        .pageBackground()
        .navigationTitle("Old Events")
    }

    // MARK: - Results

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                if !events.isEmpty {
                    summaryCard
                }

                ForEach(years, id: \.self) { year in
                    yearSection(year)
                }
            }
            .padding(Theme.screenInset)
        }
        .overlay {
            switch phase {
            case .scanning:
                ProgressView("Looking through your calendar…")
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.secondaryText)
            case .ready where events.isEmpty:
                ContentUnavailableView(
                    "Nothing to clear",
                    systemImage: "calendar",
                    description: Text("No one-off events older than a year on calendars you can edit.")
                )
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            default:
                EmptyView()
            }
        }
        .task { onScan() }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading("Older than a year")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(events.count)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text(events.count == 1 ? "past event" : "past events")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: "\(years.count) \(years.count == 1 ? "year" : "years")")
            }

            // Honest about what this is for: tidying, not space.
            Text("Events use almost no storage, so this is about a tidier calendar and search. Recurring events and read-only calendars are never included.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            Button {
                let ids = events.map(\.id)
                if allSelected {
                    plan.deselectEvents(ids)
                } else {
                    plan.selectEvents(ids)
                }
            } label: {
                Text(allSelected ? "Deselect all" : "Select all \(events.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.background, in: .rect(cornerRadius: Theme.controlCorner))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.controlCorner)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    private func yearSection(_ year: Int) -> some View {
        let yearEvents = eventsByYear[year] ?? []
        let allInYear = !yearEvents.isEmpty && yearEvents.allSatisfy { plan.isEventSelected($0.id) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading("\(String(year)) · \(yearEvents.count)")
                Button(allInYear ? "Deselect" : "Select year") {
                    let ids = yearEvents.map(\.id)
                    if allInYear { plan.deselectEvents(ids) } else { plan.selectEvents(ids) }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 0) {
                ForEach(Array(yearEvents.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().overlay(Theme.divider) }
                    row(for: event)
                }
            }
            .card(padding: 0)
        }
    }

    private func row(for event: EventRecord) -> some View {
        let isSelected = plan.isEventSelected(event.id)

        return Button {
            plan.toggleEvent(event.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? .white : .clear)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? Theme.accent : Theme.surface, in: .circle)
                    .overlay(Circle().strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(detail(for: event))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(isSelected ? "Delete" : event.calendarTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.destructive : Theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title), \(detail(for: event))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func detail(for event: EventRecord) -> String {
        var parts = [
            event.isAllDay
                ? event.start.formatted(date: .abbreviated, time: .omitted)
                : event.start.formatted(date: .abbreviated, time: .shortened),
        ]
        if let location = event.location { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Grouping

    private var eventsByYear: [Int: [EventRecord]] {
        Dictionary(grouping: events) { Calendar.current.component(.year, from: $0.start) }
    }

    /// Oldest year first, matching the scan's order: the further back, the safer to clear.
    private var years: [Int] {
        eventsByYear.keys.sorted()
    }

    private var allSelected: Bool {
        !events.isEmpty && events.allSatisfy { plan.isEventSelected($0.id) }
    }

    // MARK: - Permission

    private var gate: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            Text(gateTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)

            Text(gateExplanation)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            switch access {
            case .notDetermined:
                PrimaryActionButton(title: "Continue") {
                    Task { await onRequestAccess() }
                }
                .frame(maxWidth: 260)
            case .denied, .writeOnly:
                PrimaryActionButton(title: "Open Settings", action: onOpenSettings)
                    .frame(maxWidth: 260)
            case .restricted, .full:
                EmptyView()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gateTitle: String {
        switch access {
        case .notDetermined: "Let Slimline check your calendar"
        case .denied: "Calendar access is off"
        case .writeOnly: "Slimline can't read your calendar"
        case .restricted: "Calendar access isn't available"
        case .full: "Ready to check"
        }
    }

    private var gateExplanation: String {
        switch access {
        case .notDetermined:
            "Slimline looks for one-off events older than a year that you might want to clear. Everything stays on this iPhone, and nothing is deleted without your approval."
        case .denied:
            "Slimline can't look for old events without access. You can turn it on in Settings."
        case .writeOnly:
            "Slimline has permission to add events but not to read them, so it can't find old ones. Choose Full Access in Settings to use this."
        case .restricted:
            "Calendar access is blocked on this iPhone, probably by Screen Time or a configuration profile."
        case .full:
            ""
        }
    }
}
