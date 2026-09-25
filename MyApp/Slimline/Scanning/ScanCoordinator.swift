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
    private let snapshots = ScanSnapshotStore()
    private let keepers = KeeperPreferences()

    private var scanTask: Task<Void, Never>?
    private var contactScanTask: Task<Void, Never>?
    /// Bumped on every contact scan so a superseded run can recognise itself and stay quiet.
    private var contactScanGeneration = 0

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

    /// Everything the scan believes could be freed, across all categories.
    ///
    /// Screenshots and videos count in full because the user may remove any of them; similar
    /// photos count only their non-keepers, since one of each group always stays.
    var totalReclaimableBytes: Int64 {
        similarReclaimableBytes + screenshotBytes + videoBytes
    }

    // MARK: - Lifecycle

    func refreshStorage() async {
        storage = (try? await reporter.snapshot()) ?? .unknown
    }

    func startScan(force: Bool = false) {
        guard !isScanning else { return }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.runScan(force: force)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = similarGroups.isEmpty ? .idle : .ready
    }

    /// Scans the address book, unless a scan is already running or has already succeeded.
    ///
    /// Kept separate from the photo scan because it's gated on a different permission: a user
    /// who grants Photos but refuses Contacts should still get a full photo scan, and vice versa.
    ///
    /// Idempotent on purpose. This is called from the contacts screen's `.task`, which fires every
    /// time the tab is shown, so re-running a completed scan would be both wasteful and — because
    /// each call cancels the previous task — a way to end up reporting a stale result.
    func startContactScan(force: Bool = false) {
        if !force {
            switch contactPhase {
            case .scanning, .ready: return
            case .idle, .failed: break
            }
        }

        contactScanGeneration += 1
        let generation = contactScanGeneration

        contactScanTask?.cancel()
        contactScanTask = Task { [weak self] in
            await self?.runContactScan(generation: generation)
        }
    }

    /// Runs one contact scan, writing state only while it is still the current one.
    ///
    /// The generation check is the important part. Previously the cancelled branch set the phase
    /// back to `.idle` unconditionally, so a superseded run could land *after* a newer run had
    /// already succeeded and reset a finished scan to "not checked yet". A stale run now writes
    /// nothing at all, which is the only safe thing for it to do.
    private func runContactScan(generation: Int) async {
        guard generation == contactScanGeneration else { return }
        contactPhase = .scanning

        do {
            let groups = try await contactScanner.scan()

            guard generation == contactScanGeneration else { return }

            // The user's own choice of card beats the scan's, every time it rescans.
            duplicateContacts = KeeperPreferences.applying(keepers.contacts, to: groups)
            plan.register(contactGroups: duplicateContacts)
            contactPhase = .ready
        } catch is CancellationError {
            guard generation == contactScanGeneration else { return }
            contactPhase = .idle
        } catch {
            guard generation == contactScanGeneration else { return }
            contactPhase = .failed("Your contacts couldn't be read. Try again in a moment.")
        }
    }

    private func runScan(force: Bool) async {
        // `dataSize` is iOS 27+, so on earlier systems photo sizes come from a pixel estimate.
        // Track that up front rather than inferring it later.
        photoSizesAreEstimated = !isExactPhotoSizingAvailable

        var snapshot = force ? ScanSnapshot() : await snapshots.load()

        // A warm start usually has nothing to do, so it stays silent until real work turns up.
        // Showing a progress bar that completes instantly on every launch reads as "it rescanned
        // my whole library again", which is exactly the impression the snapshot exists to avoid.
        let isWarmStart = !snapshot.bucketGroups.isEmpty
        if !isWarmStart {
            phase = .scanning(stage: .preparing, fraction: 0)
        }

        let all = await index.fetchAll()
        let currentStamps = Self.stamps(for: all)

        async let screenshotRecords = index.fetchScreenshots()
        async let videoRecords = index.fetchVideos()

        // Sizes are cached per asset, so only genuinely new or edited items are resolved. On a
        // library with a lot of video this is the difference between a rescan taking seconds and
        // taking a minute — each unresolved video needs its own `AVAsset` round trip.
        let resolvedScreenshots = await withCachedSizes(await screenshotRecords, snapshot: snapshot)
        let resolvedVideos = await withCachedSizes(await videoRecords, snapshot: snapshot)

        guard !Task.isCancelled else {
            phase = .idle
            return
        }

        for record in resolvedScreenshots + resolvedVideos {
            if let bytes = record.byteSize { snapshot.sizes[record.id] = bytes }
        }

        // Biggest first, everywhere. The user came to free up space, so the items worth their
        // attention are the ones that would free the most of it — not the most recent.
        screenshots = resolvedScreenshots
            .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
        largeVideos = resolvedVideos
            .filter { ($0.byteSize ?? 0) > 0 }
            .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }

        do {
            let outcome = try await scanner.scan(
                records: all,
                reusableBuckets: snapshot.bucketGroups
            ) { [weak self] progress in
                // On a warm start, `preparing` carries no work worth reporting — only surface the
                // stages that mean photos are actually being analysed.
                guard !(isWarmStart && progress.stage == .preparing) else { return }
                Task { @MainActor [weak self] in
                    self?.phase = .scanning(stage: progress.stage, fraction: progress.fraction)
                }
            }

            guard !Task.isCancelled else {
                phase = .idle
                return
            }

            // Groups arrive without sizes; resolve them so "reclaimable" is a real number.
            // Applied after the scan rather than inside it, so reused buckets and freshly
            // compared ones get the same treatment: the user's star always wins.
            keepers.prunePhotos(keeping: Set(all.map(\.id)))
            similarGroups = KeeperPreferences.applying(
                keepers.photos,
                to: await withSizes(outcome.groups, snapshot: snapshot)
            )
            plan.register(groups: similarGroups)
            plan.pruneMissing(liveAssetIDs: Set(all.map(\.id)))

            for group in similarGroups {
                for asset in group.assets where asset.byteSize != nil {
                    snapshot.sizes[asset.id] = asset.byteSize
                }
            }

            snapshot.assetStamps = currentStamps
            snapshot.bucketGroups = outcome.bucketGroups
            // Drop sizes for assets that have gone, so the file doesn't grow without bound.
            snapshot.sizes = snapshot.sizes.filter { currentStamps[$0.key] != nil }
            await snapshots.save(snapshot)

            await refreshStorage()
            phase = .ready
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed("The scan couldn't finish. Pull down to try again.")
        }
    }

    private static func stamps(for records: [AssetRecord]) -> [String: Double] {
        var stamps: [String: Double] = [:]
        stamps.reserveCapacity(records.count)
        for record in records {
            stamps[record.id] = record.modificationDate?.timeIntervalSince1970 ?? 0
        }
        return stamps
    }

    /// Fills in sizes from the snapshot where they're still valid, resolving only the rest.
    private func withCachedSizes(
        _ records: [AssetRecord],
        snapshot: ScanSnapshot
    ) async -> [AssetRecord] {
        var known: [AssetRecord] = []
        var unknown: [AssetRecord] = []

        for var record in records {
            if let bytes = snapshot.sizes[record.id] {
                record.byteSize = bytes
                known.append(record)
            } else {
                unknown.append(record)
            }
        }

        guard !unknown.isEmpty else { return known }
        return known + (await sizes.resolveSizes(for: unknown))
    }

    /// Fills in byte sizes for every asset in every group.
    private func withSizes(
        _ groups: [SimilarPhotoGroup],
        snapshot: ScanSnapshot
    ) async -> [SimilarPhotoGroup] {
        let flattened = groups.flatMap(\.assets)
        let resolved = await withCachedSizes(flattened, snapshot: snapshot)
        var byID: [String: AssetRecord] = [:]
        for record in resolved { byID[record.id] = record }

        return groups
            .map { group in
                SimilarPhotoGroup(
                    id: group.id,
                    assets: Self.ordered(
                        group.assets.map { byID[$0.id] ?? $0 },
                        keeper: group.bestAssetID
                    ),
                    bestAssetID: group.bestAssetID,
                    similarity: group.similarity
                )
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Keeper first, then everything else largest first.
    ///
    /// The keeper leads regardless of its size: it's the reference the user compares the rest
    /// against, so it belongs in the top-left of the grid rather than wherever its file size
    /// happens to put it.
    static func ordered(_ assets: [AssetRecord], keeper: String) -> [AssetRecord] {
        let others = assets
            .filter { $0.id != keeper }
            .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }

        guard let best = assets.first(where: { $0.id == keeper }) else { return others }
        return [best] + others
    }

    private var isExactPhotoSizingAvailable: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// Promotes a different photo to be the one kept in its group.
    ///
    /// The scan's pick is a suggestion, not a verdict. It's right often enough to be a good
    /// default and wrong often enough that refusing to budge would be the app overruling someone
    /// about their own photos — it can rank sharpness and resolution, but not which face came out
    /// better. Re-registering the groups moves the protection across, which also drops the new
    /// keeper from the deletion set if it happened to be selected.
    func setKeeper(_ assetID: String, inGroup groupID: String) {
        guard let index = similarGroups.firstIndex(where: { $0.id == groupID }),
              similarGroups[index].assets.contains(where: { $0.id == assetID })
        else { return }

        let group = similarGroups[index]
        similarGroups[index] = SimilarPhotoGroup(
            id: group.id,
            assets: Self.ordered(group.assets, keeper: assetID),
            bestAssetID: assetID,
            similarity: group.similarity
        )

        keepers.preferPhoto(assetID, over: group.assets.map(\.id))
        plan.register(groups: similarGroups)
    }

    /// Promotes a different card to be the one kept in its duplicate-contact group.
    ///
    /// This also changes what a merge produces: the kept card is the one everything else folds
    /// into, so choosing it is a more consequential decision than for photos.
    func setPrimaryContact(_ contactID: String, inGroup groupID: String) {
        guard let index = duplicateContacts.firstIndex(where: { $0.id == groupID }),
              duplicateContacts[index].contacts.contains(where: { $0.id == contactID })
        else { return }

        let group = duplicateContacts[index]
        duplicateContacts[index] = DuplicateContactGroup(
            id: group.id,
            contacts: group.contacts,
            primaryContactID: contactID
        )

        keepers.preferContact(contactID, over: group.contacts.map(\.id))
        plan.register(contactGroups: duplicateContacts)
    }

    /// Drops deleted assets from the results without a full rescan.
    func removeFromResults(assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }

        screenshots.removeAll { assetIDs.contains($0.id) }
        largeVideos.removeAll { assetIDs.contains($0.id) }

        similarGroups = similarGroups
            .compactMap { group in
                let remaining = group.assets.filter { !assetIDs.contains($0.id) }
                // A group needs at least two members to still be a duplicate group.
                guard remaining.count > 1 else { return nil }
                let keeper = remaining.contains(where: { $0.id == group.bestAssetID })
                    ? group.bestAssetID
                    : remaining[0].id
                return SimilarPhotoGroup(
                    id: group.id,
                    assets: Self.ordered(remaining, keeper: keeper),
                    bestAssetID: keeper,
                    similarity: group.similarity
                )
            }
            // Re-sorted, because removing photos changes what each group would still free.
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }

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
