import Photos

/// Drives the scans and holds their results for the UI.
///
/// Main-actor-isolated on purpose: it owns nothing but observable state and the task that
/// produces it. All the real work happens inside the scanner and index actors, so this type never
/// blocks the UI even though the whole pipeline is kicked off from a button tap.
@Observable
final class ScanCoordinator {
    enum Phase: Equatable {
        case idle
        case scanning(stage: SimilarPhotoScanner.Stage, fraction: Double)
        case ready
        case failed(String)
    }

    /// The contact scan has no meaningful progress fraction — it's one pass over an address book
    /// that's small next to a photo library — so it gets a simpler state of its own rather than
    /// borrowing `Phase` and reporting a fake percentage.
    enum ContactPhase: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var contactPhase: ContactPhase = .idle

    private(set) var similarGroups: [SimilarPhotoGroup] = []
    private(set) var screenshots: [AssetRecord] = []
    private(set) var largeVideos: [AssetRecord] = []
    private(set) var duplicateContacts: [DuplicateContactGroup] = []
    private(set) var storage: StorageSnapshot = .unknown

    /// Set when sizes for this category are pixel-based estimates rather than measurements, so
    /// the UI can mark them as approximate instead of presenting a guess as a fact.
    private(set) var photoSizesAreEstimated = false

    let plan = CleanPlan()

    private let index = AssetIndex()
    private let sizes = AssetSizeProvider()
    private let scanner = SimilarPhotoScanner()
    private let reporter = StorageReporter()
    private let contactScanner = ContactScanner()

    private var scanTask: Task<Void, Never>?
    private var contactScanTask: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    // MARK: - Totals for the dashboard

    var similarReclaimableBytes: Int64 {
        similarGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var screenshotBytes: Int64 {
        screenshots.compactMap(\.byteSize).reduce(0, +)
    }

    var videoBytes: Int64 {
        largeVideos.compactMap(\.byteSize).reduce(0, +)
    }

    /// Contacts that could go, counting each group's duplicates but never its primary card.
    var removableContactCount: Int {
        duplicateContacts.reduce(0) { $0 + $1.duplicates.count }
    }

    // MARK: - Lifecycle

    func refreshStorage() async {
        storage = (try? await reporter.snapshot()) ?? .unknown
    }

    func startScan() {
        guard !isScanning else { return }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.runScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = similarGroups.isEmpty ? .idle : .ready
    }

    /// Scans the address book. Kept separate from the photo scan because it's gated on a different
    /// permission: a user who grants Photos but refuses Contacts should still get a full photo
    /// scan, and vice versa.
    func startContactScan() {
        guard contactPhase != .scanning else { return }

        contactScanTask?.cancel()
        contactScanTask = Task { [weak self] in
            await self?.runContactScan()
        }
    }

    private func runContactScan() async {
        contactPhase = .scanning

        do {
            let groups = try await contactScanner.scan()

            guard !Task.isCancelled else {
                contactPhase = .idle
                return
            }

            duplicateContacts = groups
            plan.register(contactGroups: groups)
            contactPhase = .ready
        } catch is CancellationError {
            contactPhase = .idle
        } catch {
            contactPhase = .failed("Your contacts couldn't be read. Try again in a moment.")
        }
    }

    private func runScan() async {
        phase = .scanning(stage: .preparing, fraction: 0)

        // `dataSize` is iOS 27+, so on earlier systems photo sizes come from a pixel estimate.
        // Track that up front rather than inferring it later.
        photoSizesAreEstimated = !isExactPhotoSizingAvailable

        let all = await index.fetchAll()

        async let screenshotRecords = index.fetchScreenshots()
        async let videoRecords = index.fetchVideos()

        let resolvedScreenshots = await sizes.resolveSizes(for: screenshotRecords)
        let resolvedVideos = await sizes.resolveSizes(for: videoRecords)

        guard !Task.isCancelled else {
            phase = .idle
            return
        }

        screenshots = resolvedScreenshots
        largeVideos = resolvedVideos
            .filter { ($0.byteSize ?? 0) > 0 }
            .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }

        do {
            let groups = try await scanner.scan(records: all) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.phase = .scanning(stage: progress.stage, fraction: progress.fraction)
                }
            }

            guard !Task.isCancelled else {
                phase = .idle
                return
            }

            // Groups arrive without sizes; resolve them so "reclaimable" is a real number.
            similarGroups = await withSizes(groups)
            plan.register(groups: similarGroups)
            plan.pruneMissing(liveAssetIDs: Set(all.map(\.id)))

            await refreshStorage()
            phase = .ready
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed("The scan couldn't finish. Pull down to try again.")
        }
    }

    /// Fills in byte sizes for every asset in every group.
    private func withSizes(_ groups: [SimilarPhotoGroup]) async -> [SimilarPhotoGroup] {
        let flattened = groups.flatMap(\.assets)
        let resolved = await sizes.resolveSizes(for: flattened)
        var byID: [String: AssetRecord] = [:]
        for record in resolved { byID[record.id] = record }

        return groups
            .map { group in
                SimilarPhotoGroup(
                    id: group.id,
                    assets: group.assets.map { byID[$0.id] ?? $0 },
                    bestAssetID: group.bestAssetID
                )
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private var isExactPhotoSizingAvailable: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// Drops deleted assets from the results without a full rescan.
    func removeFromResults(assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }

        screenshots.removeAll { assetIDs.contains($0.id) }
        largeVideos.removeAll { assetIDs.contains($0.id) }

        similarGroups = similarGroups.compactMap { group in
            let remaining = group.assets.filter { !assetIDs.contains($0.id) }
            // A group needs at least two members to still be a duplicate group.
            guard remaining.count > 1 else { return nil }
            return SimilarPhotoGroup(
                id: group.id,
                assets: remaining,
                bestAssetID: remaining.contains(where: { $0.id == group.bestAssetID })
                    ? group.bestAssetID
                    : remaining[0].id
            )
        }

        plan.register(groups: similarGroups)
    }

    /// Drops removed contacts from the results without a full rescan.
    func removeContactsFromResults(ids: Set<String>) {
        guard !ids.isEmpty else { return }

        duplicateContacts = duplicateContacts.compactMap { group in
            let remaining = group.contacts.filter { !ids.contains($0.id) }
            // Fewer than two cards left means it's no longer a duplicate group.
            guard remaining.count > 1 else { return nil }
            let primary = remaining.contains(where: { $0.id == group.primaryContactID })
                ? group.primaryContactID
                : ContactGrouping.primaryContactID(in: remaining)
            return DuplicateContactGroup(
                id: group.id,
                contacts: remaining,
                primaryContactID: primary
            )
        }

        plan.register(contactGroups: duplicateContacts)
    }
}
