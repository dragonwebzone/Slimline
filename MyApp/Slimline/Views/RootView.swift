import SwiftUI

/// Top-level shell: gates on photo access, then shows the dashboard and the scan → review →
/// clean loop.
struct RootView: View {
    @State private var photoAccess = PhotoLibraryAccess()
    @State private var contactsAccess = ContactsAccess()
    @State private var coordinator = ScanCoordinator()
    @State private var lastOutcome: DeletionService.Outcome?

    /// The user can revoke or widen access in Settings while we're backgrounded, so status is
    /// re-read on every activation rather than trusted from launch.
    @Environment(\.scenePhase) private var scenePhase

    private let deletionService = DeletionService()

    var body: some View {
        NavigationStack {
            Group {
                if photoAccess.access.canScan {
                    dashboard
                } else {
                    PermissionGateView(
                        access: photoAccess.access,
                        onRequest: { await photoAccess.request() },
                        onOpenSettings: { photoAccess.openSettings() }
                    )
                }
            }
            .navigationTitle("Slimline")
        }
        .task {
            await coordinator.refreshStorage()
            if photoAccess.access.canScan { coordinator.startScan() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            photoAccess.refresh()
            contactsAccess.refresh()
            Task { await coordinator.refreshStorage() }
        }
        .onChange(of: photoAccess.access) { _, access in
            // Access is usually granted after the first launch, so the initial `.task` runs too
            // early to scan. Kick off as soon as we're actually allowed to look.
            guard access.canScan, coordinator.phase == .idle else { return }
            coordinator.startScan()
        }
        .sheet(item: $lastOutcome) { outcome in
            ResultView(outcome: outcome) { lastOutcome = nil }
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 16) {
                StorageCard(snapshot: coordinator.storage)

                if photoAccess.access == .limited {
                    limitedAccessNotice
                }

                scanStatus

                categories

                if !coordinator.plan.isEmpty {
                    reviewButton
                }
            }
            .padding(16)
        }
        .refreshable {
            await coordinator.refreshStorage()
            coordinator.startScan()
        }
    }

    @ViewBuilder
    private var scanStatus: some View {
        switch coordinator.phase {
        case .scanning(let stage, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label(for: stage))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Stop") { coordinator.cancelScan() }
                        .font(.subheadline)
                }
                ProgressView(value: fraction)
            }
            .card()

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

        case .idle:
            Button("Scan my library") { coordinator.startScan() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

        case .ready:
            HStack {
                Label(readySummary, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Scan again") { coordinator.startScan() }
                    .font(.subheadline)
            }
            .card()
        }
    }

    private var readySummary: String {
        let found = coordinator.similarGroups.count
            + coordinator.screenshots.count
            + coordinator.largeVideos.count
        return found == 0 ? "Scan complete — nothing to clean" : "Scan complete"
    }

    private func label(for stage: SimilarPhotoScanner.Stage) -> String {
        switch stage {
        case .preparing: "Looking through your library…"
        case .analysing: "Comparing photos…"
        case .grouping: "Grouping duplicates…"
        }
    }

    private var categories: some View {
        VStack(spacing: 10) {
            NavigationLink {
                SimilarPhotosView(
                    groups: coordinator.similarGroups,
                    sizesAreEstimated: coordinator.photoSizesAreEstimated,
                    plan: coordinator.plan
                )
            } label: {
                CategoryRow(
                    title: "Similar Photos",
                    systemImage: "square.on.square",
                    detail: "\(coordinator.similarGroups.count) groups",
                    bytes: coordinator.similarReclaimableBytes
                )
            }

            NavigationLink {
                ScreenshotsView(
                    records: coordinator.screenshots,
                    sizesAreEstimated: coordinator.photoSizesAreEstimated,
                    plan: coordinator.plan
                )
            } label: {
                CategoryRow(
                    title: "Screenshots",
                    systemImage: "camera.viewfinder",
                    detail: "\(coordinator.screenshots.count) items",
                    bytes: coordinator.screenshotBytes
                )
            }

            NavigationLink {
                LargeVideosView(records: coordinator.largeVideos, plan: coordinator.plan)
            } label: {
                CategoryRow(
                    title: "Large Videos",
                    systemImage: "film",
                    detail: "\(coordinator.largeVideos.count) items",
                    bytes: coordinator.videoBytes
                )
            }

            NavigationLink {
                DuplicateContactsView(
                    groups: coordinator.duplicateContacts,
                    phase: coordinator.contactPhase,
                    access: contactsAccess.access,
                    plan: coordinator.plan,
                    onRequestAccess: {
                        await contactsAccess.request()
                        if contactsAccess.access.canScan { coordinator.startContactScan() }
                    },
                    onOpenSettings: { contactsAccess.openSettings() },
                    onScan: { coordinator.startContactScan() }
                )
            } label: {
                CategoryRow(
                    title: "Duplicate Contacts",
                    systemImage: "person.2",
                    // Contacts take up a negligible, unmeasurable amount of space, so this row
                    // reports a count instead of inventing a byte figure for it.
                    detail: contactsDetail,
                    bytes: 0
                )
            }
        }
        .buttonStyle(.plain)
    }

    private var contactsDetail: String {
        switch coordinator.contactPhase {
        case .idle: "Not checked yet"
        case .scanning: "Checking…"
        case .failed: "Couldn't be read"
        case .ready:
            coordinator.duplicateContacts.isEmpty
                ? "No duplicates"
                : "\(coordinator.duplicateContacts.count) groups"
        }
    }

    private var reviewButton: some View {
        NavigationLink {
            ReviewView(
                plan: coordinator.plan,
                sizesAreEstimated: coordinator.photoSizesAreEstimated
            ) {
                await performClean()
            }
        } label: {
            HStack {
                Text("Review \(reviewCount) selected")
                    .fontWeight(.semibold)
                Spacer()
                Text(ByteFormatting.string(coordinator.plan.totalBytes))
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Theme.accent, in: .rect(cornerRadius: Theme.cardCorner))
            .foregroundStyle(.white)
        }
    }

    /// On limited access our scan genuinely only covers the shared subset, so say that plainly
    /// and offer the picker rather than implying the whole library was checked.
    private var limitedAccessNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Limited access", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Theme.reclaimable)

            Text("Slimline can only see the photos you picked, so these results cover that selection — not your whole library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Choose more photos") {
                photoAccess.presentLimitedLibraryPicker()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var reviewCount: Int {
        coordinator.plan.totalAssetCount + coordinator.plan.totalContactsRemoved
    }

    /// Carries out everything the user approved on the review screen, in one pass.
    ///
    /// Merges run before outright contact deletions so a merge can still read every card it needs
    /// to fold in. Each stage reports separately and the results are combined, so a photo deletion
    /// failing doesn't hide a successful contact merge.
    private func performClean() async {
        let plan = coordinator.plan
        let assetIDs = plan.selectedAssetIDs
        let bytes = plan.totalBytes
        let mergeGroups = plan.mergingGroups
        let contactIDs = Array(plan.selectedContactIDs)

        var outcome = await deletionService.deleteAssets(ids: assetIDs, expectedBytes: bytes)
        outcome = outcome.combined(with: await deletionService.mergeContacts(groups: mergeGroups))
        outcome = outcome.combined(with: await deletionService.deleteContacts(ids: contactIDs))

        if outcome.assetsDeleted > 0 {
            coordinator.removeFromResults(assetIDs: Set(assetIDs))
        }

        if outcome.contactsDeleted > 0 || outcome.contactsMerged > 0 {
            // Merged cards are gone as surely as deleted ones, so both leave the results.
            let absorbed = mergeGroups.flatMap { $0.duplicates.map(\.id) }
            coordinator.removeContactsFromResults(ids: Set(contactIDs).union(absorbed))
        }

        if outcome.didAnything {
            plan.reset()
            await coordinator.refreshStorage()
        }

        lastOutcome = outcome
    }
}

/// One dashboard category row.
struct CategoryRow: View {
    let title: String
    let systemImage: String
    let detail: String
    let bytes: Int64

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // A dash rather than "0 KB" before a scan has run: zero would imply we looked and
            // found nothing, which isn't the same as not having looked yet.
            Text(bytes > 0 ? ByteFormatting.string(bytes) : "—")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .card()
        .contentShape(.rect)
    }
}

extension DeletionService.Outcome: Identifiable {
    public var id: String {
        "\(assetsRequested)-\(assetsDeleted)-\(contactsDeleted)-\(contactsMerged)-\(bytesPendingReclaim)"
    }
}
