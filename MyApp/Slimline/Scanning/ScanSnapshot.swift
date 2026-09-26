import CryptoKit
import Foundation

/// A previously computed grouping, stored by the members that produced it.
nonisolated struct StoredGroup: Codable, Sendable, Hashable {
    let memberIDs: [String]
    let keeperID: String
    /// Optional so snapshots written before similarity was recorded still decode; a `nil` simply
    /// means the group shows no percentage until the next full rescan.
    var similarity: Double?
}

/// Everything a finished scan produced, in a form that can be reloaded on the next launch.
///
/// Deliberately stores identifiers rather than whole `AssetRecord`s. The records are rebuilt from
/// the live PhotoKit fetch each launch, which keeps the file small and means a stale snapshot can
/// never resurrect a photo that has since been deleted.
nonisolated struct ScanSnapshot: Codable, Sendable {
    /// Asset identifier to modification stamp, for everything the last scan saw. This is what
    /// makes "has anything changed?" answerable without redoing any work.
    var assetStamps: [String: Double] = [:]

    /// Bucket fingerprint to the groups that bucket produced. A bucket whose membership and
    /// modification stamps are unchanged cannot have produced different groups, so its entry is
    /// reused verbatim instead of being recompared.
    var bucketGroups: [String: [StoredGroup]] = [:]

    /// Resolved byte sizes, valid for as long as the asset's stamp is unchanged. Sizes are one of
    /// the slower parts of a rescan — videos each need an `AVAsset` round trip — so they're worth
    /// keeping.
    var sizes: [String: Int64] = [:]

    /// Blur measurements, each carrying the stamp it was taken at. Optional so snapshots written
    /// before blur detection existed still decode rather than forcing a full rescan.
    var blur: [String: BlurDetector.Result]?

    /// A stable fingerprint for a bucket.
    ///
    /// Must be stable across launches, which rules out `Hasher` — Swift seeds it randomly per
    /// process, so the same bucket would fingerprint differently every time and nothing would
    /// ever hit. Sorted so member order can't affect the result, and stamped so an edited photo
    /// invalidates the bucket it sits in.
    static func bucketKey(for records: [AssetRecord]) -> String {
        let parts = records
            .map { "\($0.id):\($0.modificationDate?.timeIntervalSince1970 ?? 0)" }
            .sorted()
            .joined(separator: "|")

        let digest = SHA256.hash(data: Data(parts.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Persists the last scan so the next launch doesn't redo it.
///
/// Lives in Caches alongside the feature prints: it is entirely regenerable, and if the system
/// evicts it the only cost is one slow scan. Same plain-file reasoning as `FeaturePrintCache` —
/// read once, write once, no queries.
actor ScanSnapshotStore {
    private var snapshot = ScanSnapshot()
    private var isLoaded = false

    private let fileURL: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("slimline-scan-snapshot.plist")
    }

    func load() -> ScanSnapshot {
        if isLoaded { return snapshot }
        isLoaded = true

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? PropertyListDecoder().decode(ScanSnapshot.self, from: data)
        else { return snapshot }

        snapshot = decoded
        return snapshot
    }

    func save(_ snapshot: ScanSnapshot) {
        self.snapshot = snapshot
        isLoaded = true

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
