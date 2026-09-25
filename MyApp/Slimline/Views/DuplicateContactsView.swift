import SwiftUI

/// Duplicate contacts, grouped, with the card we suggest keeping marked.
///
/// Two actions per group, because the brief asks for both and they mean different things: *merge*
/// folds every detail into the primary card and removes the rest, while *selecting* a card queues
/// it for outright deletion in the review screen. Merging is the safer default and is offered
/// first, since it never loses a phone number.
struct DuplicateContactsView: View {
    let groups: [DuplicateContactGroup]
    let phase: ScanCoordinator.ContactPhase
    let access: ContactAccess
    let plan: CleanPlan
    let onRequestAccess: () async -> Void
    let onOpenSettings: () -> Void
    let onScan: () -> Void
    /// Explicit retry, which must run even when the last attempt left the phase at `.failed`.
    let onRescan: () -> Void
    /// Promotes a card to be the one kept, and the one a merge folds everything into.
    let onMakePrimary: (String, String) -> Void

    var body: some View {
        Group {
            if access.canScan {
                content
            } else {
                gate
            }
        }
        .pageBackground()
    }

    // MARK: - Results

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                if !groups.isEmpty {
                    summaryCard
                }

                if access == .limited {
                    notice(
                        "Slimline can only see the contacts you shared, so these results cover that selection — not your whole address book.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                if case .failed(let message) = phase {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                        Button("Try again", action: onRescan)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                ForEach(groups) { group in
                    ContactGroupCard(
                        group: group,
                        plan: plan,
                        onMakePrimary: { onMakePrimary($0, group.id) }
                    )
                }
            }
            .padding(Theme.screenInset)
        }
        .overlay {
            switch phase {
            case .scanning:
                ProgressView("Checking your contacts…")
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.secondaryText)
            case .idle where groups.isEmpty:
                ContentUnavailableView {
                    Label("Not checked yet", systemImage: "person.2")
                } description: {
                    Text("Look through your contacts for duplicate entries.")
                } actions: {
                    Button("Check contacts", action: onRescan)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            case .ready where groups.isEmpty:
                ContentUnavailableView(
                    "No duplicates",
                    systemImage: "checkmark.circle",
                    description: Text("Every contact looks unique.")
                )
            default:
                EmptyView()
            }
        }
        .task {
            // Safe to call on every appearance: the coordinator ignores this once a scan is
            // running or has finished, so returning to the tab never re-scans or discards the
            // selections the user just made.
            onScan()
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading("Duplicate Entries")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(removableCount)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text(removableCount == 1 ? "card to tidy" : "cards to tidy")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: "\(groups.count) sets")
            }

            Text("Merging folds every phone number and email onto the starred card. Tap a star to keep a different one. Contact changes can't be undone.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            Button {
                withAnimation(.snappy) {
                    for group in groups where plan.isMerging(group.id) == allMerging {
                        plan.toggleMerge(group)
                    }
                }
            } label: {
                Text(allMerging ? "Undo all merges" : "Merge all \(groups.count) sets")
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
            .disabled(groups.isEmpty)
        }
        .card()
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(Theme.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)
    }

    private var removableCount: Int {
        groups.reduce(0) { $0 + $1.duplicates.count }
    }

    private var allMerging: Bool {
        !groups.isEmpty && groups.allSatisfy { plan.isMerging($0.id) }
    }

    // MARK: - Permission

    /// Contacts access is asked for here rather than at launch: the user has just opened the
    /// contacts tab, so the reason for the prompt is obvious.
    private var gate: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
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
            case .denied:
                PrimaryActionButton(title: "Open Settings", action: onOpenSettings)
                    .frame(maxWidth: 260)
            case .restricted, .limited, .full:
                EmptyView()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gateTitle: String {
        switch access {
        case .notDetermined: "Let Slimline check your contacts"
        case .denied: "Contacts access is off"
        case .restricted: "Contacts access isn't available"
        case .limited, .full: "Ready to check"
        }
    }

    private var gateExplanation: String {
        switch access {
        case .notDetermined:
            "Slimline needs to read your contacts to spot duplicate entries. Everything happens on this iPhone, and nothing is changed without your approval."
        case .denied:
            "Slimline can't look for duplicate contacts without access. You can turn it back on in Settings."
        case .restricted:
            "Contacts access is blocked on this iPhone, probably by Screen Time or a configuration profile."
        case .limited, .full:
            ""
        }
    }
}

/// One set of contacts that look like the same person.
private struct ContactGroupCard: View {
    let group: DuplicateContactGroup
    let plan: CleanPlan
    let onMakePrimary: (String) -> Void

    private var isMerging: Bool { plan.isMerging(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 0) {
                ForEach(Array(group.contacts.enumerated()), id: \.element.id) { index, contact in
                    if index > 0 {
                        Divider().overlay(Theme.divider)
                    }
                    row(for: contact)
                }
            }
            .background(Theme.background, in: .rect(cornerRadius: Theme.innerCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.innerCorner)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }

            mergeButton

            if isMerging {
                mergePreview
            }
        }
        .card(padding: 12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.primary.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("\(group.contacts.count) entries look like the same person")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            // Why these were matched, so the suggestion is never a black box.
            Chip(text: group.reason)
        }
    }

    private func row(for contact: ContactRecord) -> some View {
        let isProtected = plan.isContactProtected(contact.id)
        let isSelected = plan.isContactSelected(contact.id)

        return HStack(spacing: 10) {
            // A star on every row, tappable on all but the current keeper. The scan's choice is
            // the most complete card, which is a good guess and not always the right one — the
            // user may want their own spelling of a name, or a specific card's photo.
            Button {
                withAnimation(.snappy) { onMakePrimary(contact.id) }
            } label: {
                Image(systemName: isProtected ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isProtected ? .white : Theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(isProtected ? Theme.accent : Theme.surface, in: .circle)
                    .overlay(
                        Circle().strokeBorder(
                            isProtected ? Theme.accent : Theme.divider,
                            lineWidth: 1
                        )
                    )
                    .frame(width: 34, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isProtected)
            .accessibilityLabel(isProtected ? "Kept card" : "Keep this card instead")

            // The kept card gets a blank of the same size rather than nothing, so names stay in
            // one column instead of jumping left on whichever row happens to be starred.
            if isProtected {
                Circle()
                    .fill(Theme.surface.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
            } else {
                Button {
                    plan.toggleContact(contact.id)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .clear)
                        .frame(width: 22, height: 22)
                        .background(isSelected ? Theme.accent : Theme.surface, in: .circle)
                        .overlay(
                            Circle().strokeBorder(
                                isSelected ? Theme.accent : Theme.divider,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canToggle(contact))
                .accessibilityLabel(isSelected ? "Selected for deletion" : "Not selected")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(contact.displayName)
                    .font(.system(size: 14, weight: isProtected ? .semibold : .regular))
                    .foregroundStyle(Theme.primaryText)
                Text(contact.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Text(isProtected ? "Keep" : (isSelected ? "Delete" : "Review"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.destructive : Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .opacity(isMerging && !isProtected ? 0.45 : 1)
    }

    private var mergeButton: some View {
        Button {
            withAnimation(.snappy) { plan.toggleMerge(group) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isMerging ? "checkmark.circle.fill" : "arrow.triangle.merge")
                    .font(.system(size: 13, weight: .medium))
                Text(isMerging ? "Merging — tap to undo" : "Merge into one contact")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(isMerging ? .white : Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isMerging ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.background),
                in: .rect(cornerRadius: Theme.controlCorner)
            )
            .overlay {
                if !isMerging {
                    RoundedRectangle(cornerRadius: Theme.controlCorner)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Shows the card the merge will produce. The same `mergedFields` call performs the merge, so
    /// this preview can't drift from the result.
    private var mergePreview: some View {
        let fields = ContactGrouping.mergedFields(for: group)

        return VStack(alignment: .leading, spacing: 5) {
            SectionHeading("Kept as one contact")

            Text([fields.givenName, fields.familyName].filter { !$0.isEmpty }.joined(separator: " "))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            ForEach(fields.phoneNumbers, id: \.self) { number in
                Label(number, systemImage: "phone")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(fields.emailAddresses, id: \.self) { email in
                Label(email, systemImage: "envelope")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.background, in: .rect(cornerRadius: Theme.innerCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.innerCorner)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// A card already covered by a merge can't also be deleted outright — the merge needs to read
    /// it, and counting it twice would overstate what the review screen is about to remove.
    private func canToggle(_ contact: ContactRecord) -> Bool {
        plan.isContactSelected(contact.id) || plan.canSelectContact(contact.id)
    }
}
