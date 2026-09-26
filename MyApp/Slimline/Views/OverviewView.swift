import SwiftUI

/// The Overview tab: what's on the device, what the scan found, and where to go next.
struct OverviewView: View {
    let coordinator: ScanCoordinator
    let photoAccess: PhotoLibraryAccess
    let contactPhase: ScanCoordinator.ContactPhase
    /// Tapping a tile selects that tab rather than pushing a copy of the screen, so the tab bar
    /// stays the single source of navigation and the back gesture never gets confusing.
    let onSelect: (RootView.Tab) -> Void
    /// Lands on a specific segment of the Photos tab, so the Blurry tile opens Blurry.
    let onSelectPhotos: (SimilarPhotosView.Filter) -> Void
    let onOpenCalendar: () -> Void
    let onOpenVault: () -> Void
    let onOpenKept: () -> Void

    @State private var isSwiping = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.sectionSpacing) {
                StorageCard(
                    snapshot: coordinator.storage,
                    reclaimableBytes: coordinator.totalReclaimableBytes
                )

                if photoAccess.access == .limited {
                    limitedAccessNotice
                }

                scanStatus

                swipeCard

                if coordinator.history.cleans > 0 {
                    historyCard
                }

                VStack(spacing: 8) {
                    SectionHeading("What's taking up space")
                    categoryTiles
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .fullScreenCover(isPresented: $isSwiping) {
            SwipeReviewView(
                title: "Swipe Through",
                records: coordinator.swipeCandidates,
                plan: coordinator.plan
            )
        }
        .refreshable {
            await coordinator.refreshStorage()
            coordinator.startScan(force: true)
        }
    }

    // MARK: - Swipe

    /// One way into swipe review that covers everything suggested, rather than one per category.
    ///
    /// Placed high and styled as the primary thing to do, because for most people it is: going
    /// through suggestions one photo at a time is quicker than learning five separate screens.
    @ViewBuilder
    private var swipeCard: some View {
        let candidates = coordinator.swipeCandidates
        if coordinator.phase == .ready, !candidates.isEmpty {
            let bytes = candidates.compactMap(\.byteSize).reduce(0, +)
            Button { isSwiping = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.18), in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Swipe through photos & videos")
                            .font(.system(size: 16, weight: .semibold))
                        Text("\(candidates.count) suggestions · \(ByteFormatting.string(bytes))")
                            .font(.system(size: 13))
                            .opacity(0.85)
                            .contentTransition(.numericText())
                        Text("Left to delete, right to keep")
                            .font(.system(size: 12))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(16)
                .background(Theme.accent, in: .rect(cornerRadius: Theme.cardCorner))
                .contentShape(.rect(cornerRadius: Theme.cardCorner))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Swipe through \(candidates.count) suggested photos and videos")
            .accessibilityHint("Swipe left to mark for deletion, right to keep for good")
        }
    }

    // MARK: - Scan state

    @ViewBuilder
    private var scanStatus: some View {
        switch coordinator.phase {
        case .scanning(let stage, let fraction):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label(for: stage))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Button("Stop") { coordinator.cancelScan() }
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                }
                // Indeterminate while preparing: there's no denominator yet, and a bar sitting at
                // zero looks like a stall rather than like work starting.
                if fraction > 0 {
                    ProgressView(value: fraction).tint(Theme.accent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
            }
            .card()

        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                    Button("Try again") { coordinator.startScan(force: true) }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .card()

        case .idle:
            PrimaryActionButton(title: "Scan my library", systemImage: "sparkle.magnifyingglass") {
                coordinator.startScan()
            }

        case .ready:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                Text(readySummary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Rescan") { coordinator.startScan(force: true) }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .card(padding: 14)
        }
    }

    /// A small running tally. Worth the space because it's the one figure that shows the app has
    /// actually done something over time, rather than only what it could do next.
    private var historyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(ByteFormatting.string(coordinator.history.bytes)) cleared so far")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .contentTransition(.numericText())
                Text("\(coordinator.history.items) items across \(coordinator.history.cleans) \(coordinator.history.cleans == 1 ? "clean" : "cleans")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .card(padding: 14)
    }

    private var readySummary: String {
        coordinator.totalReclaimableBytes > 0
            ? "\(ByteFormatting.string(coordinator.totalReclaimableBytes)) worth reviewing"
            : "Nothing to clean up"
    }

    private func label(for stage: SimilarPhotoScanner.Stage) -> String {
        switch stage {
        case .preparing: "Looking through your library…"
        case .analysing: "Comparing photos…"
        case .grouping: "Grouping duplicates…"
        }
    }

    // MARK: - Category summary

    /// A two-column grid of the categories.
    ///
    /// Tiles rather than a list because these are peers the user picks between, not a ranked
    /// sequence to read top to bottom — and because a tile has room for the figure that actually
    /// drives the choice, which is how much each one would free.
    @ViewBuilder
    private var categoryTiles: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
            spacing: 8
        ) {
            CategoryTile(
                title: "Similar Photos",
                systemImage: "square.on.square",
                bytes: coordinator.similarReclaimableBytes,
                detail: coordinator.similarGroups.isEmpty
                    ? scannedDetail(for: coordinator.phase)
                    : "\(coordinator.similarGroups.count) sets"
            ) { onSelectPhotos(.similar) }

            CategoryTile(
                title: "Large Videos",
                systemImage: "play.rectangle",
                bytes: coordinator.videoBytes,
                detail: coordinator.largeVideos.isEmpty
                    ? scannedDetail(for: coordinator.phase)
                    : "\(coordinator.largeVideos.count) items"
            ) { onSelect(.videos) }

            CategoryTile(
                title: "Screenshots",
                systemImage: "crop",
                bytes: coordinator.screenshotBytes,
                detail: coordinator.screenshots.isEmpty
                    ? scannedDetail(for: coordinator.phase)
                    : "\(coordinator.screenshots.count) items"
            ) { onSelect(.screenshots) }

            CategoryTile(
                title: "Blurry Photos",
                systemImage: "camera.aperture",
                bytes: coordinator.blurryBytes,
                detail: blurryDetail
            ) { onSelectPhotos(.blurry) }

            CategoryTile(
                title: "Duplicate Contacts",
                systemImage: "person.2",
                // Contacts take up a negligible, unmeasurable amount of space, so this tile leads
                // with a count instead of inventing a byte figure for it.
                bytes: 0,
                countLabel: contactCountLabel,
                detail: contactsDetail
            ) { onSelect(.contacts) }

            CategoryTile(
                title: "Old Events",
                systemImage: "calendar",
                // Events take up no meaningful space either, so this leads with a count too.
                bytes: 0,
                countLabel: coordinator.calendarPhase == .ready && !coordinator.oldEvents.isEmpty
                    ? "\(coordinator.oldEvents.count)"
                    : nil,
                detail: calendarDetail
            ) { onOpenCalendar() }
        }

        // Set apart from the grid: the vault stores things rather than clearing them, so it
        // doesn't belong among the categories of what's taking up space.
        Button(action: onOpenVault) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceDim, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Private Vault")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Keep photos behind \(VaultLock.methodName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText.opacity(0.5))
            }
            .card(padding: 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)

        // Only once something has been kept: before that there's nothing to manage, and an empty
        // row would just be noise.
        if coordinator.kept.count > 0 {
            Button(action: onOpenKept) {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(Theme.surfaceDim, in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Kept Photos")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text("\(coordinator.kept.count) no longer suggested")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText.opacity(0.5))
                }
                .card(padding: 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var calendarDetail: String {
        switch coordinator.calendarPhase {
        case .idle: "Not checked yet"
        case .scanning: "Checking…"
        case .failed: "Couldn't be read"
        case .ready: coordinator.oldEvents.isEmpty ? "Nothing to clear" : "Older than a year"
        }
    }

    private var blurryDetail: String {
        if coordinator.blurProgress != nil { return "Checking…" }
        if coordinator.phase != .ready { return "Not scanned yet" }
        return coordinator.blurryPhotos.isEmpty ? "None found" : "\(coordinator.blurryPhotos.count) photos"
    }

    private var contactCountLabel: String? {
        guard contactPhase == .ready, !coordinator.duplicateContacts.isEmpty else { return nil }
        let count = coordinator.duplicateContacts.reduce(0) { $0 + $1.duplicates.count }
        return "\(count)"
    }

    private func scannedDetail(for phase: ScanCoordinator.Phase) -> String {
        phase == .ready ? "No duplicates" : "Not scanned yet"
    }

    private var contactsDetail: String {
        switch contactPhase {
        case .idle: "Not checked yet"
        case .scanning: "Checking…"
        case .failed: "Couldn't be read"
        case .ready:
            coordinator.duplicateContacts.isEmpty
                ? "No duplicates"
                : "\(coordinator.duplicateContacts.count) sets"
        }
    }

    /// On limited access our scan genuinely only covers the shared subset, so say that plainly
    /// and offer the picker rather than implying the whole library was checked.
    private var limitedAccessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Limited access", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.warning)

            Text("Slimline can only see the photos you picked, so these results cover that selection — not your whole library.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)

            Button("Choose more photos") {
                photoAccess.presentLimitedLibraryPicker()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

#Preview("Category tiles") {
    ScrollView {
        VStack(spacing: 8) {
            SectionHeading("What's taking up space")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                CategoryTile(
                    title: "Similar Photos",
                    systemImage: "square.on.square",
                    bytes: 4_820_000_000,
                    detail: "84 sets"
                ) {}
                CategoryTile(
                    title: "Large Videos",
                    systemImage: "play.rectangle",
                    bytes: 12_400_000_000,
                    detail: "37 items"
                ) {}
                CategoryTile(
                    title: "Screenshots",
                    systemImage: "crop",
                    bytes: 268_000_000,
                    detail: "412 items"
                ) {}
                CategoryTile(
                    title: "Duplicate Contacts",
                    systemImage: "person.2",
                    bytes: 0,
                    countLabel: "9",
                    detail: "4 sets"
                ) {}
            }
        }
        .padding(Theme.screenInset)
    }
    .pageBackground()
}

/// One tappable category tile.
struct CategoryTile: View {
    let title: String
    let systemImage: String
    let bytes: Int64
    /// Used instead of a byte figure where bytes are meaningless — contacts.
    var countLabel: String?
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(Theme.surfaceDim, in: .rect(cornerRadius: 9))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText.opacity(0.5))
                }

                Spacer(minLength: 12)

                // A dash rather than "0 KB" before a scan has run: zero would imply we looked and
                // found nothing, which isn't the same as not having looked yet.
                Text(headline)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(bytes > 0 || countLabel != nil ? Theme.primaryText : Theme.secondaryText)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 126)
            .card(padding: 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(headline), \(detail)")
        .accessibilityAddTraits(.isButton)
    }

    private var headline: String {
        if let countLabel { return countLabel }
        return bytes > 0 ? ByteFormatting.string(bytes) : "—"
    }
}
