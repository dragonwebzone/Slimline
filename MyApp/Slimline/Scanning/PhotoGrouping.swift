import Foundation

/// Disjoint-set union, used to turn a pile of "these two look alike" pairs into groups.
///
/// Comparing A-B and B-C separately would otherwise leave A and C in different groups even
/// though they belong together.
nonisolated struct UnionFind {
    private var parent: [Int]
    private var size: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        size = Array(repeating: 1, count: count)
    }

    mutating func find(_ element: Int) -> Int {
        var root = element
        while parent[root] != root { root = parent[root] }
        // Path compression: flatten the chain so repeated lookups stay near-constant.
        var current = element
        while parent[current] != current {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        // Union by size, to keep trees shallow.
        if size[rootA] < size[rootB] {
            parent[rootA] = rootB
            size[rootB] += size[rootA]
        } else {
            parent[rootB] = rootA
            size[rootA] += size[rootB]
        }
    }

    /// Groups of two or more, as index lists.
    mutating func clusters() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for element in parent.indices {
            byRoot[find(element), default: []].append(element)
        }
        return byRoot.values.filter { $0.count > 1 }.map { $0.sorted() }
    }
}

/// A group of photos that look like the same shot.
nonisolated struct SimilarPhotoGroup: Sendable, Identifiable {
    let id: String
    let assets: [AssetRecord]
    /// The one we suggest keeping. Never pre-selected for deletion.
    let bestAssetID: String

    var others: [AssetRecord] { assets.filter { $0.id != bestAssetID } }

    /// What deleting everything except the best shot would reclaim.
    var reclaimableBytes: Int64 {
        others.compactMap(\.byteSize).reduce(0, +)
    }
}

/// The pure, testable half of duplicate detection: which photos are even worth comparing, and
/// how comparison results become groups.
///
/// Keeping this free of PhotoKit and Vision is what makes the scan logic unit-testable without a
/// photo library — the simulator has almost none, so this is the only way to get real coverage.
nonisolated enum PhotoGrouping {
    /// Default window for "these were taken as part of the same moment".
    static let defaultWindow: TimeInterval = 20

    /// Splits the library into small buckets that are plausibly the same shot.
    ///
    /// This is the single most important performance decision in the app. Comparing every photo
    /// against every other is O(n²) — on a 20,000-photo library that's 200 million comparisons
    /// and the scan never finishes. Near-identical shots are essentially always taken seconds
    /// apart, so bucketing by a short time window and then by aspect ratio reduces the work to
    /// the sum of many tiny O(k²) problems.
    ///
    /// Assets with no creation date are dropped: there's nothing to bucket them by, and treating
    /// them as one giant bucket would reintroduce the O(n²) blowup we're avoiding.
    static func candidateBuckets(
        for records: [AssetRecord],
        window: TimeInterval = defaultWindow
    ) -> [[AssetRecord]] {
        let dated = records
            .filter { $0.creationDate != nil && !$0.isVideo }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        guard !dated.isEmpty else { return [] }

        // Sweep into runs of consecutive photos taken close together in time.
        var runs: [[AssetRecord]] = []
        var currentRun: [AssetRecord] = [dated[0]]

        for record in dated.dropFirst() {
            let previous = currentRun[currentRun.count - 1]
            let gap = (record.creationDate ?? .distantPast)
                .timeIntervalSince(previous.creationDate ?? .distantPast)
            if gap <= window {
                currentRun.append(record)
            } else {
                runs.append(currentRun)
                currentRun = [record]
            }
        }
        runs.append(currentRun)

        // Then split each run by shape, so a portrait and a landscape shot taken back to back
        // never get compared.
        return runs
            .flatMap { run -> [[AssetRecord]] in
                Dictionary(grouping: run, by: \.aspectBucket).values.map { $0 }
            }
            .filter { $0.count > 1 }
    }

    /// Byte-identical copies, found without any image analysis at all.
    ///
    /// Same size, same dimensions and same capture time is a strong enough signal to treat as a
    /// duplicate. Unlike similar-shot detection this is deliberately global rather than
    /// time-bucketed, because a re-saved or re-downloaded copy can sit years away from its twin.
    /// Only runs on records whose size is known.
    static func exactDuplicateGroups(for records: [AssetRecord]) -> [[AssetRecord]] {
        struct Fingerprint: Hashable {
            let bytes: Int64
            let width: Int
            let height: Int
            let capturedAt: Date?
        }

        let sized = records.filter { $0.byteSize != nil && ($0.byteSize ?? 0) > 0 }
        let buckets = Dictionary(grouping: sized) {
            Fingerprint(
                bytes: $0.byteSize ?? 0,
                width: $0.pixelWidth,
                height: $0.pixelHeight,
                capturedAt: $0.creationDate
            )
        }
        return buckets.values.filter { $0.count > 1 }.map { $0 }
    }

    /// Picks the keeper in a group.
    ///
    /// Favourites win outright — the user already told us that one matters. After that we trust
    /// Vision's aesthetics score, then resolution, then edits, then recency. Returns the asset ID
    /// so callers don't have to care about ordering.
    static func bestAssetID(in group: [AssetRecord], aestheticScores: [String: Float]) -> String {
        precondition(!group.isEmpty, "A similar-photo group is never empty")

        let ranked = group.max { lhs, rhs in
            isRankedBelow(lhs, rhs, aestheticScores: aestheticScores)
        }
        return ranked?.id ?? group[0].id
    }

    /// True when `lhs` is a worse keeper than `rhs`.
    private static func isRankedBelow(
        _ lhs: AssetRecord,
        _ rhs: AssetRecord,
        aestheticScores: [String: Float]
    ) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return rhs.isFavorite }

        let lhsScore = aestheticScores[lhs.id]
        let rhsScore = aestheticScores[rhs.id]
        if let lhsScore, let rhsScore, lhsScore != rhsScore { return lhsScore < rhsScore }
        // A scored photo beats an unscored one; an unscored photo shouldn't win by default.
        if (lhsScore == nil) != (rhsScore == nil) { return lhsScore == nil }

        if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount < rhs.pixelCount }
        if lhs.hasAdjustments != rhs.hasAdjustments { return rhs.hasAdjustments }

        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        return lhsDate < rhsDate
    }

    /// Assembles final groups from within-bucket match pairs.
    static func assembleGroups(
        bucket: [AssetRecord],
        matchedPairs: [(Int, Int)],
        aestheticScores: [String: Float]
    ) -> [SimilarPhotoGroup] {
        guard !matchedPairs.isEmpty else { return [] }

        var unionFind = UnionFind(count: bucket.count)
        for (a, b) in matchedPairs {
            unionFind.union(a, b)
        }

        return unionFind.clusters().map { indices in
            let assets = indices.map { bucket[$0] }
            let best = bestAssetID(in: assets, aestheticScores: aestheticScores)
            return SimilarPhotoGroup(id: best, assets: assets, bestAssetID: best)
        }
    }
}
