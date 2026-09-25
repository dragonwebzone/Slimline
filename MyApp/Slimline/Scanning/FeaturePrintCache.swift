import Foundation

/// On-disk cache of Vision feature prints, keyed by asset.
///
/// This is what makes a second scan feel instant: generating a feature print requires decoding a
/// thumbnail and running a model, which dominates scan time. Photos are immutable in practice, so
/// a print stays valid until the asset is edited — hence keying on `modificationDate` as well as
/// identifier.
///
/// Deliberately a plain file rather than SwiftData. The access pattern is "read everything once,
/// write everything once" with no queries, relationships or UI binding, so a store would add
/// concurrency friction and buy nothing. It lives in Caches because it is fully regenerable and
/// the system is welcome to evict it.
actor FeaturePrintCache {
    nonisolated struct Entry: Codable, Sendable {
        /// `modificationDate` as a time interval. A change invalidates the print.
        let modificationStamp: Double
        /// An encoded `FeaturePrintObservation` for the whole frame.
        let payload: Data
        /// An encoded `FeaturePrintObservation` for the centre of the frame.
        ///
        /// Optional only so that caches written before this existed still decode. A `nil` here is
        /// treated as a miss, so those entries are regenerated rather than compared on the
        /// whole-frame print alone.
        let centerPayload: Data?
        /// Vision's aesthetics score, cached alongside so best-shot picking is also incremental.
        let aestheticScore: Float?
    }

    private var entries: [String: Entry] = [:]
    private var isLoaded = false
    private var isDirty = false

    private let fileURL: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("slimline-feature-prints.plist")
    }

    func load() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let data = try? Data(contentsOf: fileURL) else { return }
        // A corrupt or stale-format cache is not worth surfacing to the user; the worst case is
        // one slow scan while it rebuilds.
        entries = (try? PropertyListDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Returns a cached print only if it still matches the asset's modification stamp.
    func entry(for assetID: String, modificationStamp: Double) -> Entry? {
        guard let entry = entries[assetID] else { return nil }
        guard entry.modificationStamp == modificationStamp else { return nil }
        return entry
    }

    func store(_ entry: Entry, for assetID: String) {
        entries[assetID] = entry
        isDirty = true
    }

    /// Drops entries for assets that no longer exist, so the file doesn't grow without bound as
    /// the user deletes photos.
    func prune(keeping liveAssetIDs: Set<String>) {
        let before = entries.count
        entries = entries.filter { liveAssetIDs.contains($0.key) }
        if entries.count != before { isDirty = true }
    }

    func persist() {
        guard isDirty else { return }

        let encoder = PropertyListEncoder()
        // Binary keeps the `Data` blobs compact; XML would base64 them and bloat the file.
        encoder.outputFormat = .binary

        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
        isDirty = false
    }
}
