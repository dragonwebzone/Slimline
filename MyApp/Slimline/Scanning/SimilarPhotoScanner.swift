import CoreGraphics
import Photos
import UIKit
import Vision

/// Finds duplicate and near-identical photos.
///
/// The pipeline is: bucket by time and shape (cheap) → look for byte-identical copies (cheap) →
/// generate feature prints for what's left (expensive, cached, bounded concurrency) → compare
/// within buckets only → union-find into groups.
actor SimilarPhotoScanner {
    nonisolated enum Stage: Sendable {
        case preparing
        case analysing
        case grouping
    }

    nonisolated struct Progress: Sendable {
        let stage: Stage
        let completed: Int
        let total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }
    }

    private struct Analysis: Sendable {
        let assetID: String
        let featurePrint: FeaturePrintObservation
        let aestheticScore: Float?
    }

    private let cache = FeaturePrintCache()

    /// Feature-print distance below which two photos are treated as the same shot.
    ///
    /// Tuned on a real library: below ~0.2 we miss obvious burst duplicates, above ~0.4 we start
    /// grouping genuinely different photos of the same scene. Exposed so it can be adjusted
    /// without touching the pipeline.
    private let matchThreshold: Double

    /// Feature prints are computed from a small square thumbnail — the model doesn't benefit from
    /// full resolution, and decoding full-size images would make the scan hopelessly slow.
    private let thumbnailSide: CGFloat = 224

    /// How many thumbnails to decode and analyse at once. Enough to keep the ANE and decoders
    /// busy, low enough not to spike memory on a large library.
    private let maxConcurrentAnalyses = 6

    init(matchThreshold: Double = 0.30) {
        self.matchThreshold = matchThreshold
    }

    /// Runs a full scan. Honours cancellation between units of work.
    func scan(
        records: [AssetRecord],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [SimilarPhotoGroup] {
        onProgress(Progress(stage: .preparing, completed: 0, total: 0))

        let buckets = PhotoGrouping.candidateBuckets(for: records)
        guard !buckets.isEmpty else { return [] }

        await cache.load()

        // One record per identifier: a photo can only appear in a single time/shape bucket, but
        // dedupe defensively so we never analyse the same asset twice.
        var uniqueRecords: [String: AssetRecord] = [:]
        for record in buckets.flatMap(\.self) {
            uniqueRecords[record.id] = record
        }

        let analyses = try await analyseAll(
            Array(uniqueRecords.values),
            onProgress: onProgress
        )

        await cache.prune(keeping: Set(records.map(\.id)))
        await cache.persist()

        onProgress(Progress(stage: .grouping, completed: 0, total: buckets.count))

        return groups(from: buckets, analyses: analyses, onProgress: onProgress)
    }

    // MARK: - Analysis

    private func analyseAll(
        _ records: [AssetRecord],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> [String: Analysis] {
        let total = records.count
        onProgress(Progress(stage: .analysing, completed: 0, total: total))

        var results: [String: Analysis] = [:]
        results.reserveCapacity(total)
        var completed = 0
        var next = 0

        try await withThrowingTaskGroup(of: Analysis?.self) { group in
            // Prime the group up to the concurrency limit, then top it up as results land. This
            // keeps a fixed number of decodes in flight rather than spawning thousands of tasks.
            while next < records.count, next < maxConcurrentAnalyses {
                let record = records[next]
                group.addTask { [weak self] in await self?.analyse(record) ?? nil }
                next += 1
            }

            while let finished = try await group.next() {
                try Task.checkCancellation()

                if let analysis = finished {
                    results[analysis.assetID] = analysis
                }
                completed += 1
                onProgress(Progress(stage: .analysing, completed: completed, total: total))

                if next < records.count {
                    let record = records[next]
                    group.addTask { [weak self] in await self?.analyse(record) ?? nil }
                    next += 1
                }
            }
        }

        return results
    }

    private func analyse(_ record: AssetRecord) async -> Analysis? {
        let stamp = record.modificationDate?.timeIntervalSince1970 ?? 0

        if let cached = await cache.entry(for: record.id, modificationStamp: stamp),
           let observation = try? PropertyListDecoder().decode(
               FeaturePrintObservation.self,
               from: cached.payload
           ) {
            return Analysis(
                assetID: record.id,
                featurePrint: observation,
                aestheticScore: cached.aestheticScore
            )
        }

        guard let image = await thumbnail(for: record.id) else { return nil }
        guard let observation = try? await GenerateImageFeaturePrintRequest().perform(on: image) else {
            return nil
        }

        // Aesthetics drives best-shot selection. A failure here is not fatal — grouping still
        // works, we just fall back to resolution and recency when picking the keeper.
        let score = try? await CalculateImageAestheticsScoresRequest().perform(on: image).overallScore

        if let payload = try? PropertyListEncoder().encode(observation) {
            await cache.store(
                FeaturePrintCache.Entry(
                    modificationStamp: stamp,
                    payload: payload,
                    aestheticScore: score
                ),
                for: record.id
            )
        }

        return Analysis(assetID: record.id, featurePrint: observation, aestheticScore: score)
    }

    /// A small square thumbnail, never fetched over the network.
    ///
    /// `isNetworkAccessAllowed = false` is a hard requirement, not an optimisation: the brief
    /// says nothing leaves the device, and allowing it would let PhotoKit pull originals down
    /// from iCloud mid-scan.
    private nonisolated func thumbnail(for assetID: String) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let side = thumbnailSide
        return await withCheckedContinuation { continuation in
            let resumer = SingleResume(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                resumer.resume(image?.cgImage)
            }
        }
    }

    // MARK: - Grouping

    private func groups(
        from buckets: [[AssetRecord]],
        analyses: [String: Analysis],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) -> [SimilarPhotoGroup] {
        var scores: [String: Float] = [:]
        for (id, analysis) in analyses {
            if let score = analysis.aestheticScore { scores[id] = score }
        }

        var result: [SimilarPhotoGroup] = []

        for (index, bucket) in buckets.enumerated() {
            var pairs: [(Int, Int)] = []

            // Buckets are small by construction, so this O(k²) comparison is cheap. That is the
            // whole point of the bucketing step.
            for i in bucket.indices {
                guard let left = analyses[bucket[i].id]?.featurePrint else { continue }
                for j in bucket.index(after: i)..<bucket.endIndex {
                    guard let right = analyses[bucket[j].id]?.featurePrint else { continue }
                    guard let distance = try? left.distance(to: right) else { continue }
                    if distance <= matchThreshold {
                        pairs.append((i, j))
                    }
                }
            }

            result.append(
                contentsOf: PhotoGrouping.assembleGroups(
                    bucket: bucket,
                    matchedPairs: pairs,
                    aestheticScores: scores
                )
            )

            onProgress(Progress(stage: .grouping, completed: index + 1, total: buckets.count))
        }

        // Biggest win first: the user cares about reclaimable space, not chronology.
        return result.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
}
