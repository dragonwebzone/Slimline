import SwiftUI

/// The Overview tab: what's on the device, what the scan found, and where to go next.
struct OverviewView: View {
    let coordinator: ScanCoordinator
    let photoAccess: PhotoLibraryAccess
    let contactPhase: ScanCoordinator.ContactPhase
    /// Tapping a tile selects that tab rather than pushing a copy of the screen, so the tab bar
    /// stays the single source of navigation and the back gesture never gets confusing.
    let onSelect: (RootView.Tab) -> Void

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

                VStack(spacing: 8) {
                    SectionHeading("What's taking up space")
                    categoryTiles
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .refreshable {
            await coordinator.refreshStorage()
            coordinator.startScan(force: true)
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

    /// A 2×2 grid of the four categories.
    ///
    /// Tiles rather than a list because these are four peers the user picks between, not a ranked
    /// sequence to read top to bottom — and because a tile has room for the figure that actually
    /// drives the choice, which is how much each one would free.
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
            ) { onSelect(.photos) }

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
                title: "Duplicate Contacts",
                systemImage: "person.2",
                // Contacts take up a negligible, unmeasurable amount of space, so this tile leads
                // with a count instead of inventing a byte figure for it.
                bytes: 0,
                countLabel: contactCountLabel,
                detail: contactsDetail
            ) { onSelect(.contacts) }
        }
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
                        .background(Theme.surfaceDim, in: .rect(cornerRadius: 7))
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
