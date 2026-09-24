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

    var body: some View {
        Group {
            if access.canScan {
                content
            } else {
                gate
            }
        }
        .navigationTitle("Duplicate Contacts")
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        List {
            if access == .limited {
                Section {
                    Label(
                        "Slimline can only see the contacts you shared, so these results cover that selection — not your whole address book.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try again", action: onScan)
                }
            }

            ForEach(groups) { group in
                section(for: group)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(allMerging ? "Undo All" : "Merge All") {
                    for group in groups {
                        if plan.isMerging(group.id) == allMerging {
                            plan.toggleMerge(group)
                        }
                    }
                }
                .disabled(groups.isEmpty)
            }
        }
        .overlay {
            switch phase {
            case .scanning:
                ProgressView("Checking your contacts…")
            case .idle where groups.isEmpty:
                ContentUnavailableView {
                    Label("Not checked yet", systemImage: "person.2")
                } description: {
                    Text("Look through your contacts for duplicate entries.")
                } actions: {
                    Button("Check contacts", action: onScan)
                        .buttonStyle(.borderedProminent)
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
            // Only scan on first arrival; coming back from the review screen shouldn't throw away
            // the selections the user just made.
            if phase == .idle { onScan() }
        }
    }

    private func section(for group: DuplicateContactGroup) -> some View {
        Section {
            ForEach(group.contacts) { contact in
                row(for: contact, in: group)
            }

            Button {
                plan.toggleMerge(group)
            } label: {
                Label(
                    plan.isMerging(group.id) ? "Merging — tap to undo" : "Merge into one contact",
                    systemImage: plan.isMerging(group.id)
                        ? "checkmark.circle.fill"
                        : "arrow.triangle.merge"
                )
                .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Theme.accent)

            if plan.isMerging(group.id) {
                mergePreview(for: group)
            }
        } header: {
            HStack {
                Text(group.primary.displayName)
                Spacer()
                Text(group.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("\(group.contacts.count) entries look like the same person.")
        }
    }

    private func row(for contact: ContactRecord, in group: DuplicateContactGroup) -> some View {
        HStack(spacing: 12) {
            if plan.isContactProtected(contact.id) {
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.reclaimable)
                    .frame(width: 22)
                    .accessibilityLabel("Suggested to keep")
            } else {
                Button {
                    plan.toggleContact(contact.id)
                } label: {
                    Image(
                        systemName: plan.isContactSelected(contact.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(plan.isContactSelected(contact.id) ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 22)
                .disabled(!canToggle(contact))
                .accessibilityLabel(
                    plan.isContactSelected(contact.id) ? "Selected for deletion" : "Not selected"
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.body.weight(plan.isContactProtected(contact.id) ? .semibold : .regular))
                Text(contact.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if plan.isContactProtected(contact.id) {
                Text("Keep")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(plan.isMerging(group.id) && !plan.isContactProtected(contact.id) ? 0.5 : 1)
    }

    /// Shows the card the merge will produce. The same `mergedFields` call performs the merge, so
    /// this preview can't drift from the result.
    private func mergePreview(for group: DuplicateContactGroup) -> some View {
        let fields = ContactGrouping.mergedFields(for: group)

        return VStack(alignment: .leading, spacing: 4) {
            Text("Kept as one contact")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text([fields.givenName, fields.familyName].filter { !$0.isEmpty }.joined(separator: " "))
                .font(.subheadline.weight(.medium))

            ForEach(fields.phoneNumbers, id: \.self) { number in
                Label(number, systemImage: "phone")
                    .font(.caption)
            }
            ForEach(fields.emailAddresses, id: \.self) { email in
                Label(email, systemImage: "envelope")
                    .font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    /// A card already covered by a merge can't also be deleted outright — the merge needs to read
    /// it, and counting it twice would overstate what the review screen is about to remove.
    private func canToggle(_ contact: ContactRecord) -> Bool {
        plan.isContactSelected(contact.id) || plan.canSelectContact(contact.id)
    }

    private var allMerging: Bool {
        !groups.isEmpty && groups.allSatisfy { plan.isMerging($0.id) }
    }

    // MARK: - Permission

    /// Contacts access is asked for here rather than at launch: the user has just tapped into the
    /// contacts feature, so the reason for the prompt is obvious. The photo gate handles its own
    /// permission the same way at the root.
    private var gate: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(gateTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(gateExplanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch access {
            case .notDetermined:
                Button("Continue") {
                    Task { await onRequestAccess() }
                }
                .buttonStyle(.borderedProminent)
            case .denied:
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
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
