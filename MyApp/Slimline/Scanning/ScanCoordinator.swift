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
    /// Same shape as contacts: one pass, no meaningful progress fraction.
    private(set) var calendarPhase: ContactPhase = .idle

    private(set) var similarGroups: [SimilarPhotoGroup] = []
    private(set) var screenshots: [AssetRecord] = []
    private(set) var largeVideos: [AssetRecord] = []
    private(set) var duplicateContacts: [DuplicateContactGroup] = []
    /// Old, one-off events on editable calendars, oldest first.
    private(set) var oldEvents: [EventRecord] = []
    /// Photos both blur signals agree on, largest first.
    private(set) var blurryPhotos: [AssetRecord] = []
    /// Progress of the blur pass, held in its own observable object.
    ///
    /// It changes up to a hundred times per pass. Stored here directly, every change invalidated
    /// every view that read anything from the coordinator — the root view, and so all five tabs,
    /// plus the Overview's totals — which is what made the app lag while blur ran. In its own
    /// object, only the views that actually show the progress bar redraw.
    let blurStatus = BlurStatus()

    /// Progress of the blur pass while it's measuring new photos; `nil` when idle or when every
    /// photo was already measured, so a warm start shows nothing.
    var blurProgress: Double? { blurStatus.progress }
    private(set) var storage: StorageSnapshot = .unknown

    /// Set when sizes for this category are pixel-based estimates rather than measurements, so
    /// the UI can mark them as approximate instead of presenting a guess as a fact.
    private(set) var photoSizesAreEstimated = false

    let plan = CleanPlan()
    /// Everything cleared so far, across sessions.
    let history = CleanupHistory()
    /// Photos the user has kept for good, which no result ever shows again.
    let kept = KeptPhotos()

    private let index = AssetIndex()
    private let sizes = AssetSizeProvider()
    private let scanner = SimilarPhotoScanner()
    private let reporter = StorageReporter()
    private let contactScanner = ContactScanner()
    private let snapshots = ScanSnapshotStore()
    private let keepers = KeeperPreferences()
    private let blurDetector = BlurDetector()
    private let calendarScanner = CalendarScanner()
    private var calendarScanGeneration = 0
    private var blurTask: Task<Void, Never>?

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
        // Counted by identity, not by summing categories: a blurry screenshot, or a blurry photo
        // that's also a similar-shot extra, would otherwise be counted twice and the headline
        // would promise space that doesn't exist.
        let keepers = Set(similarGroups.map(\.bestAssetID))
        var seen: Set<String> = []
        var total: Int64 = 0
        let candidates = similarGroups.flatMap(\.others) + screenshots + largeVideos
            + blurryPhotos.filter { !keepers.contains($0.id) }
        for record in candidates where seen.insert(record.id).inserted {
            total += record.byteSize ?? 0
        }
        return total
    }

    /// Everything suggested, for swiping through in one go: similar-set extras, blurry photos,
    /// screenshots and large videos, largest first, each photo once.
    ///
    /// A set's best shot is left out, the same as on the Blurry tab: it's the one the set
    /// suggests keeping, so offering it for a swipe would contradict that.
    var swipeCandidates: [AssetRecord] {
        let bestShots = Set(similarGroups.map(\.bestAssetID))
        var seen: Set<String> = []
        let all = similarGroups.flatMap(\.others) + blurryPhotos + screenshots + largeVideos
        return all
            .filter { !bestShots.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
    }

    /// What clearing every blurry photo would free, excluding any that are a group's keeper.
    var blurryBytes: Int64 {
        let keepers = Set(similarGroups.map(\.bestAssetID))
        return blurryPhotos
            .filter { !keepers.contains($0.id) }
            .compactMap(\.byteSize)
            .reduce(0, +)
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
        // Kept photos are filtered here as well as after grouping, since these two lists appear
        // on screen before the similarity scan finishes.
        screenshots = resolvedScreenshots
            .filter { !kept.contains($0.id) }
            .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
        largeVideos = resolvedVideos
            .filter { ($0.byteSize ?? 0) > 0 && !kept.contains($0.id) }
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
            kept.prune(keeping: Set(all.map(\.id)))
            hideKept()

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

            // Blur runs after the main results are on screen rather than holding them up. On a
            // first scan it has the whole library to measure; the user shouldn't wait for that to
            // see their duplicates.
            startBlurPass(all)
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

    // MARK: - Calendar

    /// Same idempotent, generation-guarded shape as the contact scan, for the same reasons: it's
    /// called on launch and on every visit, and a superseded run must never overwrite a newer one.
    func startCalendarScan(force: Bool = false) {
        if !force {
            switch calendarPhase {
            case .scanning, .ready: return
            case .idle, .failed: break
            }
        }

        calendarScanGeneration += 1
        let generation = calendarScanGeneration
        calendarPhase = .scanning

        Task { [weak self] in
            guard let self else { return }
            let events = await calendarScanner.scan()
            guard generation == calendarScanGeneration else { return }
            oldEvents = events
            plan.pruneEvents(keeping: Set(events.map(\.id)))
            calendarPhase = .ready
        }
    }

    /// Drops deleted events from the results without a rescan.
    func removeEventsFromResults(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        oldEvents.removeAll { ids.contains($0.id) }
    }

    // MARK: - Blur

    private func startBlurPass(_ records: [AssetRecord]) {
        blurTask?.cancel()
        // Screenshots are excluded because flat UI is edgeless by design, and videos because a
        // single frame says nothing about whether the clip is in focus.
        let candidates = records.filter { !$0.isVideo && !$0.isScreenshot }
        // Background priority: blur is a nice-to-have that runs while the user is already using
        // the results, so it should yield to anything they're actually doing.
        blurTask = Task(priority: .utility) { [weak self] in
            // Exact duplicates first: they're certain, so they're the most valuable thing the
            // background can add, and the pass is fast once sizes and prints are cached.
            await self?.runExactDuplicatePass(records)
            await self?.runBlurPass(candidates)
        }
    }

    // MARK: - Exact duplicates

    /// Finds copies of the same photo that the time buckets can't, and adds them as groups.
    ///
    /// The similarity scan only compares photos taken close together, so a copy saved or
    /// imported years after its original is invisible to it. This matches on exact byte size and
    /// dimensions across the whole library, then confirms each match visually.
    ///
    /// Skipped where sizes are pixel estimates rather than measurements (before iOS 27): there,
    /// every photo of the same resolution would share a "size", and the metadata match would mean
    /// nothing.
    private func runExactDuplicatePass(_ records: [AssetRecord]) async {
        guard isExactPhotoSizingAvailable else { return }

        let photos = records.filter { !$0.isVideo }
        var snapshot = await snapshots.load()
        // Resolving every photo's size is the slow part on a first run. It's cached per asset,
        // so later launches only pay for new photos.
        let sized = await withCachedSizes(photos, snapshot: snapshot)
        guard !Task.isCancelled else { return }

        snapshot = await snapshots.load()
        for record in sized {
            if let bytes = record.byteSize { snapshot.sizes[record.id] = bytes }
        }
        await snapshots.save(snapshot)

        // Photos already in a similar group are left out, so no photo is ever in two groups —
        // which would let the same file be counted, and offered for deletion, twice.
        let grouped = Set(similarGroups.flatMap { $0.assets.map(\.id) })
        let candidates = PhotoGrouping.exactDuplicateCandidates(
            for: sized,
            excluding: grouped.union(kept.ids)
        )
        guard !candidates.isEmpty else { return }

        let found = await scanner.confirmExactDuplicates(candidates)
        guard !found.isEmpty, !Task.isCancelled else { return }

        let ordered = found.map { group in
            SimilarPhotoGroup(
                id: group.id,
                assets: Self.ordered(group.assets, keeper: group.bestAssetID),
                bestAssetID: group.bestAssetID,
                similarity: group.similarity
            )
        }
        similarGroups = KeeperPreferences.applying(keepers.photos, to: similarGroups + ordered)
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        plan.register(groups: similarGroups)
    }

    /// Photos measured per batch before results are published and saved.
    private let blurBatchSize = 250

    /// Measures blur in batches, newest photos first, publishing and saving after each one.
    ///
    /// Batched for two reasons, both about how long a first pass over a whole library takes:
    ///
    /// - **Results appear as they're found.** Recent photos are measured first — `fetchAll` is
    ///   newest first — so the ones most worth clearing show up within seconds rather than after
    ///   the entire library has been read.
    /// - **Progress survives interruption.** Saving only at the end meant that leaving the app
    ///   part-way, and iOS suspending it, threw the whole pass away. Each batch is now kept, so
    ///   the next launch picks up where this one stopped.
    private func runBlurPass(_ candidates: [AssetRecord]) async {
        var measured = await snapshots.load().blur ?? [:]

        // Only photos without a valid cached measurement count towards the progress bar, so a
        // resumed pass shows how much is genuinely left rather than restarting at zero.
        let pendingTotal = candidates.filter { record in
            !(measured[record.id].map { BlurDetector.isCurrent($0, for: record) } ?? false)
        }.count

        var done = 0
        var found: [AssetRecord] = []

        for start in stride(from: 0, to: candidates.count, by: blurBatchSize) {
            guard !Task.isCancelled else { break }

            let batch = Array(candidates[start..<min(start + blurBatchSize, candidates.count)])
            let doneBefore = done
            let results = await blurDetector.analyse(batch, cached: measured) { [weak self] progress in
                guard pendingTotal > 0 else { return }
                let fraction = Double(doneBefore + progress.completed) / Double(pendingTotal)
                Task { @MainActor [weak self] in
                    self?.blurStatus.progress = min(1, fraction)
                }
            }
            let batchPending = batch.filter { record in
                !(measured[record.id].map { BlurDetector.isCurrent($0, for: record) } ?? false)
            }.count
            done += batchPending
            measured.merge(results) { _, new in new }

            let blurryInBatch = batch.filter { record in
                results[record.id].map(BlurDetector.isBlurry) ?? false
            }

            // Reloaded rather than reused: a photo scan may have saved in the meantime, and
            // writing back an older copy would silently discard it.
            var snapshot = await snapshots.load()
            let sized = await withCachedSizes(blurryInBatch, snapshot: snapshot)
            found.append(contentsOf: sized)
            // Published only when this batch found something (or on the first batch, to replace
            // any stale list). Every assignment redraws everything that shows blurry photos, and
            // most batches of a library find nothing new.
            if !sized.isEmpty || start == 0 {
                // Filtered at publish rather than up front, so a photo kept mid-pass drops out too.
                blurryPhotos = found
                    .filter { !kept.contains($0.id) }
                    .sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
            }

            // A warm start has nothing new to measure, so it has nothing to write either.
            guard batchPending > 0 else { continue }
            snapshot.blur = measured
            for record in sized {
                if let bytes = record.byteSize { snapshot.sizes[record.id] = bytes }
            }
            await snapshots.save(snapshot)
        }

        guard !Task.isCancelled else {
            blurStatus.progress = nil
            return
        }

        // Drop measurements for photos that no longer exist, once the pass has seen everything.
        let live = Set(candidates.map(\.id))
        var snapshot = await snapshots.load()
        snapshot.blur = measured.filter { live.contains($0.key) }
        await snapshots.save(snapshot)
        blurStatus.progress = nil
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
        let wasDeletingOthers = plan.isDeletingOthers(group)
        let updated = DuplicateContactGroup(
            id: group.id,
            contacts: group.contacts,
            primaryContactID: contactID
        )
        duplicateContacts[index] = updated

        keepers.preferContact(contactID, over: group.contacts.map(\.id))
        plan.register(contactGroups: duplicateContacts)

        // "Delete the others" is about the set, not particular cards: moving the kept card should
        // leave the previous keeper queued in its place rather than silently dropping the choice.
        if wasDeletingOthers, !plan.isDeletingOthers(updated) {
            plan.toggleDeleteOthers(updated)
        }
    }

    /// Keeps photos for good: they leave every result now and on every later scan.
    ///
    /// Taking them out of the plan too matters — a photo selected for deletion and then kept would
    /// otherwise still be deleted, from a screen that no longer shows it.
    func keepForGood(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        kept.keep(ids)
        for id in ids { plan.deselect(id) }
        removeFromResults(assetIDs: Set(ids))
    }

    /// Lets kept photos be suggested again.
    ///
    /// Results only ever hold what's still suggested, so the released photos come back through a
    /// warm rescan. The snapshot makes that cheap: nothing unchanged is analysed again.
    func showAgain(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        kept.release(ids)
        startScan()
    }

    /// Takes every kept photo out of the freshly published results.
    private func hideKept() {
        guard !kept.ids.isEmpty else { return }
        for id in kept.ids where plan.isSelected(id) { plan.deselect(id) }
        removeFromResults(assetIDs: kept.ids)
    }

    /// Drops deleted assets from the results without a full rescan.
    func removeFromResults(assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }

        screenshots.removeAll { assetIDs.contains($0.id) }
        largeVideos.removeAll { assetIDs.contains($0.id) }
        blurryPhotos.removeAll { assetIDs.contains($0.id) }
        similarGroups = Self.removing(assetIDs, from: similarGroups)
        plan.register(groups: similarGroups)
    }

    /// The groups with the given photos taken out.
    ///
    /// A group left with a single photo is dropped, since one photo isn't a duplicate of anything.
    /// If the keeper was among those removed, the next photo takes its place, so a group always
    /// has one protected member. Pure and static so the rule can be tested without a library.
    static func removing(_ ids: Set<String>, from groups: [SimilarPhotoGroup]) -> [SimilarPhotoGroup] {
        groups
            .compactMap { group in
                let remaining = group.assets.filter { !ids.contains($0.id) }
                guard remaining.count > 1 else { return nil }
                guard remaining.count != group.assets.count else { return group }
                let keeper = remaining.contains(where: { $0.id == group.bestAssetID })
                    ? group.bestAssetID
                    : remaining[0].id
                return SimilarPhotoGroup(
                    id: group.id,
                    assets: ordered(remaining, keeper: keeper),
                    bestAssetID: keeper,
                    similarity: group.similarity
                )
            }
            // Re-sorted, because removing photos changes what each group would still free.
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
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

/// The blur pass's progress, observed separately from the rest of the scan results.
@Observable
final class BlurStatus {
    /// `nil` when the pass isn't measuring anything.
    var progress: Double?
}
