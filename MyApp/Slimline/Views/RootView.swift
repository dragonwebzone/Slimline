import SwiftUI

/// Top-level shell: gates on photo access, then presents the five tabs.
///
/// A tab bar rather than a dashboard that pushes into categories. The categories are peers, not
/// children — someone who only wants to clear screenshots shouldn't have to go via a storage
/// summary — and a tab bar keeps the review bar in the same place on every screen.
struct RootView: View {
    @State private var photoAccess = PhotoLibraryAccess()
    @State private var contactsAccess = ContactsAccess()
    @State private var coordinator = ScanCoordinator()
    @State private var lastOutcome: DeletionService.Outcome?
    @State private var selectedTab = Tab.overview

    /// The user can revoke or widen access in Settings while we're backgrounded, so status is
    /// re-read on every activation rather than trusted from launch.
    @Environment(\.scenePhase) private var scenePhase

    private let deletionService = DeletionService()

    enum Tab: Hashable {
        case overview, photos, videos, screenshots, contacts
    }

    var body: some View {
        Group {
            if photoAccess.access.canScan {
                tabs
            } else {
                NavigationStack {
                    PermissionGateView(
                        access: photoAccess.access,
                        onRequest: { await photoAccess.request() },
                        onOpenSettings: { photoAccess.openSettings() }
                    )
                    .pageBackground()
                }
            }
        }
        .tint(Theme.accent)
        .task {
            await coordinator.refreshStorage()
            if photoAccess.access.canScan { coordinator.startScan() }
            scanContactsIfAlreadyPermitted()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            photoAccess.refresh()
            contactsAccess.refresh()
            Task { await coordinator.refreshStorage() }
        }
        .onChange(of: contactsAccess.access) { _, _ in
            scanContactsIfAlreadyPermitted()
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

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            tab(.overview, "Overview", "chart.pie") {
                OverviewView(
                    coordinator: coordinator,
                    photoAccess: photoAccess,
                    contactPhase: coordinator.contactPhase,
                    onSelect: { selectedTab = $0 }
                )
                .navigationTitle("Slimline")
            }

            tab(.photos, "Photos", "photo.on.rectangle.angled") {
                SimilarPhotosView(
                    groups: coordinator.similarGroups,
                    sizesAreEstimated: coordinator.photoSizesAreEstimated,
                    plan: coordinator.plan,
                    onMakeKeeper: { assetID, groupID in
                        coordinator.setKeeper(assetID, inGroup: groupID)
                    }
                )
                .navigationTitle("Similar Photos")
            }

            tab(.videos, "Videos", "play.rectangle") {
                LargeVideosView(records: coordinator.largeVideos, plan: coordinator.plan)
                    .navigationTitle("Large Videos")
            }

            tab(.screenshots, "Screenshots", "crop") {
                ScreenshotsView(
                    records: coordinator.screenshots,
                    sizesAreEstimated: coordinator.photoSizesAreEstimated,
                    plan: coordinator.plan
                )
                .navigationTitle("Screenshots")
            }

            tab(.contacts, "Contacts", "person.2") {
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
                    onScan: { coordinator.startContactScan() },
                    onRescan: { coordinator.startContactScan(force: true) },
                    onMakePrimary: { contactID, groupID in
                        coordinator.setPrimaryContact(contactID, inGroup: groupID)
                    }
                )
                .navigationTitle("Duplicate Contacts")
            }
        }
    }

    /// One tab, wrapped in its own navigation stack and carrying the review bar.
    ///
    /// The bar is attached here rather than inside each screen so the category views stay unaware
    /// of the deletion flow and keep taking nothing but a `CleanPlan`.
    private func tab<Content: View>(
        _ value: Tab,
        _ title: String,
        _ symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .reviewBar(
                    plan: coordinator.plan,
                    sizesAreEstimated: coordinator.photoSizesAreEstimated
                ) { await performClean() }
        }
        .tabItem { Label(title, systemImage: symbol) }
        .tag(value)
    }

    /// Scans contacts at launch, but only when access was already granted.
    ///
    /// Contact results aren't persisted the way the photo scan is, so without this the Overview
    /// reported "not checked yet" after every relaunch until the user happened to open the
    /// Contacts tab. Caching them instead would be the wrong trade: an address book changes
    /// constantly and syncs from other devices, so a restored list would frequently describe
    /// contacts that no longer exist, and the scan itself is cheap — no image analysis, just a
    /// pass over the address book.
    ///
    /// Crucially this never *requests* permission. A launch-time contacts prompt with no
    /// explanation is exactly what the permission gate exists to avoid; if access hasn't been
    /// granted yet, this does nothing and the tab asks properly when the user goes there.
    private func scanContactsIfAlreadyPermitted() {
        guard contactsAccess.access.canScan else { return }
        coordinator.startContactScan()
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

extension DeletionService.Outcome: Identifiable {
    public var id: String {
        "\(assetsRequested)-\(assetsDeleted)-\(contactsDeleted)-\(contactsMerged)-\(bytesPendingReclaim)"
    }
}
