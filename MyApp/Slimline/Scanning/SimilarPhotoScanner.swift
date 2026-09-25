import CoreGraphics
import os
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
        /// A second print over the centre of the frame. See `subjectThreshold`.
        let centerFeaturePrint: FeaturePrintObservation
        let aestheticScore: Float?
    }

    private let cache = FeaturePrintCache()

    /// Whole-frame distance below which two photos are treated as the same shot.
    ///
    /// A feature print is a *semantic* descriptor, which sets a hard limit on what any threshold
    /// here can achieve: "person standing on a road" and "different person standing on the same
    /// road" are genuinely close in that space. The only reliable separation is to demand near
    /// identity — real burst duplicates sit far below this, and anything merely similar does not.
    /// Deliberately strict: missing a duplicate costs the user some space, while a false positive
    /// offers up a photo they never meant to delete.
    private let matchThreshold: Double

    /// Centre-crop distance, as a second opinion on the same pair.
    ///
    /// Weaker than it first appears, for the reason above: the centre of two portraits both encode
    /// "a face", so this narrows the gap less than the background-dominance argument suggests. Kept
    /// because it costs one cached print and does filter some pairs the frame test lets through,
    /// but the strictness of `matchThreshold` is what actually does the work.
    private let subjectThreshold: Double

    /// Fraction of each side kept when cropping to the subject.
    ///
    /// 60% is a compromise: tight enough that the background stops dominating, wide enough that an
    /// off-centre subject is usually still inside it.
    private let subjectCropFraction: CGFloat = 0.6

    /// Feature prints are computed from a small square thumbnail — the model doesn't benefit from
    /// full resolution, and decoding full-size images would make the scan hopelessly slow.
    private let thumbnailSide: CGFloat = 224

    /// How many thumbnails to decode and analyse at once. Enough to keep the ANE and decoders
    /// busy, low enough not to spike memory on a large library.
    private let maxConcurrentAnalyses = 6

    init(matchThreshold: Double = 0.15, subjectThreshold: Double = 0.15) {
        self.matchThreshold = matchThreshold
        self.subjectThreshold = subjectThreshold
    }

    /// What a scan produced: the groups to show, and the per-bucket results to carry forward.
    nonisolated struct Outcome: Sendable {
        let groups: [SimilarPhotoGroup]
        /// Keyed by `ScanSnapshot.bucketKey`, for reuse by the next scan.
        let bucketGroups: [String: [StoredGroup]]
    }

    /// Runs a scan, reusing any bucket whose membership is unchanged since last time.
    ///
    /// The reuse is what makes a rescan proportional to what the user actually added rather than
    /// to the size of their library. A bucket is a set of photos taken close together in the same
    /// shape; if none of them has changed, the comparison between them cannot have changed
    /// either, so its previous result stands. Only buckets containing something new are
    /// recompared, and only genuinely new photos pay for a feature print.
    ///
    /// Honours cancellation between units of work.
    func scan(
        records: [AssetRecord],
        reusableBuckets: [String: [StoredGroup]],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Outcome {
        onProgress(Progress(stage: .preparing, completed: 0, total: 0))

        let buckets = PhotoGrouping.candidateBuckets(for: records)
        guard !buckets.isEmpty else { return Outcome(groups: [], bucketGroups: [:]) }

        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Split the work before doing any of it: buckets we've seen in exactly this state before
        // need no analysis at all.
        var staleBuckets: [[AssetRecord]] = []
        var reusedGroups: [SimilarPhotoGroup] = []
        var carried: [String: [StoredGroup]] = [:]

        for bucket in buckets {
            let key = ScanSnapshot.bucketKey(for: bucket)
            guard let stored = reusableBuckets[key] else {
                staleBuckets.append(bucket)
                continue
            }
            carried[key] = stored
            reusedGroups.append(contentsOf: stored.compactMap { rebuild($0, from: recordsByID) })
        }

        // Nothing new: return without reporting progress at all, so the UI never flashes a scan
        // that did no work.
        guard !staleBuckets.isEmpty else {
            return Outcome(
                groups: reusedGroups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
                bucketGroups: carried
            )
        }

        await cache.load()

        // One record per identifier: a photo can only appear in a single time/shape bucket, but
        // dedupe defensively so we never analyse the same asset twice.
        var uniqueRecords: [String: AssetRecord] = [:]
        for record in staleBuckets.flatMap(\.self) {
            uniqueRecords[record.id] = record
        }

        let analyses = try await analyseAll(
            Array(uniqueRecords.values),
            onProgress: onProgress
        )

        await cache.prune(keeping: Set(records.map(\.id)))
        await cache.persist()

        onProgress(Progress(stage: .grouping, completed: 0, total: staleBuckets.count))

        let fresh = groups(from: staleBuckets, analyses: analyses, onProgress: onProgress)

        for (key, groups) in fresh.byBucket {
            carried[key] = groups
        }

        return Outcome(
            groups: (reusedGroups + fresh.groups).sorted { $0.reclaimableBytes > $1.reclaimableBytes },
            bucketGroups: carried
        )
    }

    /// Turns a stored group back into a live one, dropping members that no longer exist.
    ///
    /// Returns `nil` if fewer than two survive — one photo is not a duplicate group — or if the
    /// keeper itself has gone, since re-nominating a keeper is a decision the next full scan
    /// should make rather than something to guess at here.
    private nonisolated func rebuild(
        _ stored: StoredGroup,
        from recordsByID: [String: AssetRecord]
    ) -> SimilarPhotoGroup? {
        let members = stored.memberIDs.compactMap { recordsByID[$0] }
        guard members.count > 1,
              members.contains(where: { $0.id == stored.keeperID })
        else { return nil }

        return SimilarPhotoGroup(
            id: stored.keeperID,
            assets: members,
            bestAssetID: stored.keeperID,
            similarity: stored.similarity
        )
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

        // Both prints have to be present for a cache hit. An entry written before the centre print
        // existed is regenerated rather than half-used.
        if let cached = await cache.entry(for: record.id, modificationStamp: stamp),
           let centerPayload = cached.centerPayload,
           let observation = try? PropertyListDecoder().decode(
               FeaturePrintObservation.self,
               from: cached.payload
           ),
           let centerObservation = try? PropertyListDecoder().decode(
               FeaturePrintObservation.self,
               from: centerPayload
           ) {
            return Analysis(
                assetID: record.id,
                featurePrint: observation,
                centerFeaturePrint: centerObservation,
                aestheticScore: cached.aestheticScore
            )
        }

        guard let image = await thumbnail(for: record.id) else { return nil }
        guard let observation = try? await GenerateImageFeaturePrintRequest().perform(on: image) else {
            return nil
        }

        // No centre print means we can't tell "same place" from "same shot", so rather than fall
        // back to the frame print alone — which is what caused the false positives — drop the
        // photo from consideration entirely. Missing a duplicate is recoverable; offering someone
        // else's photo for deletion is not.
        guard let cropped = centerCrop(image),
              let centerObservation = try? await GenerateImageFeaturePrintRequest().perform(on: cropped)
        else { return nil }

        // Aesthetics drives best-shot selection. A failure here is not fatal — grouping still
        // works, we just fall back to resolution and recency when picking the keeper.
        let score = try? await CalculateImageAestheticsScoresRequest().perform(on: image).overallScore

        if let payload = try? PropertyListEncoder().encode(observation),
           let centerPayload = try? PropertyListEncoder().encode(centerObservation) {
            await cache.store(
                FeaturePrintCache.Entry(
                    modificationStamp: stamp,
                    payload: payload,
                    centerPayload: centerPayload,
                    aestheticScore: score
                ),
                for: record.id
            )
        }

        return Analysis(
            assetID: record.id,
            featurePrint: observation,
            centerFeaturePrint: centerObservation,
            aestheticScore: score
        )
    }

    /// The middle of the frame, where the subject of a photo almost always is.
    private nonisolated func centerCrop(_ image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropWidth = (width * subjectCropFraction).rounded()
        let cropHeight = (height * subjectCropFraction).rounded()

        guard cropWidth >= 1, cropHeight >= 1 else { return nil }

        return image.cropping(
            to: CGRect(
                x: ((width - cropWidth) / 2).rounded(),
                y: ((height - cropHeight) / 2).rounded(),
                width: cropWidth,
                height: cropHeight
            )
        )
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
    ) -> (groups: [SimilarPhotoGroup], byBucket: [String: [StoredGroup]]) {
        var scores: [String: Float] = [:]
        for (id, analysis) in analyses {
            if let score = analysis.aestheticScore { scores[id] = score }
        }

        var result: [SimilarPhotoGroup] = []
        var byBucket: [String: [StoredGroup]] = [:]

        for (index, bucket) in buckets.enumerated() {
            var pairs: [(Int, Int)] = []

            // Buckets are small by construction, so this O(k²) comparison is cheap. That is the
            // whole point of the bucketing step.
            for i in bucket.indices {
                guard let left = analyses[bucket[i].id] else { continue }
                for j in bucket.index(after: i)..<bucket.endIndex {
                    guard let right = analyses[bucket[j].id] else { continue }
                    if isSameShot(left, right) {
                        pairs.append((i, j))
                    }
                }
            }

            let assembled = PhotoGrouping.assembleGroups(
                bucket: bucket,
                matchedPairs: pairs,
                aestheticScores: scores
            )
            .map { group in
                var scored = group
                scored.similarity = similarity(within: group, analyses: analyses)
                return scored
            }
            result.append(contentsOf: assembled)

            // Recorded even when empty: "this bucket produced no duplicates" is exactly as worth
            // remembering as a positive result, and is the common case.
            byBucket[ScanSnapshot.bucketKey(for: bucket)] = assembled.map {
                StoredGroup(
                    memberIDs: $0.assets.map(\.id),
                    keeperID: $0.bestAssetID,
                    similarity: $0.similarity
                )
            }

            onProgress(Progress(stage: .grouping, completed: index + 1, total: buckets.count))
        }

        // Biggest win first: the user cares about reclaimable space, not chronology.
        return (result.sorted { $0.reclaimableBytes > $1.reclaimableBytes }, byBucket)
    }

    /// How alike the least-alike pair in a group is.
    ///
    /// The worst pair rather than the best, because a group is built transitively: A matches B and
    /// B matches C puts all three together even though A and C were never compared. Reporting the
    /// closest pair would overstate how alike the group is as a whole.
    private func similarity(
        within group: SimilarPhotoGroup,
        analyses: [String: Analysis]
    ) -> Double? {
        let prints = group.assets.compactMap { analyses[$0.id]?.featurePrint }
        guard prints.count > 1 else { return nil }

        var worst: Double = 0
        for i in prints.indices {
            for j in prints.index(after: i)..<prints.endIndex {
                guard let distance = try? prints[i].distance(to: prints[j]) else { continue }
                worst = max(worst, distance)
            }
        }

        return max(0, 1 - worst)
    }

    /// Whether two photos are the same shot rather than merely the same place.
    ///
    /// Both tests have to pass, but see `matchThreshold`: the frame test doing its job depends far
    /// more on how strict it is than on the centre test backing it up.
    private func isSameShot(_ lhs: Analysis, _ rhs: Analysis) -> Bool {
        guard let frameDistance = try? lhs.featurePrint.distance(to: rhs.featurePrint) else {
            return false
        }
        let subjectDistance = try? lhs.centerFeaturePrint.distance(to: rhs.centerFeaturePrint)

        let matched = frameDistance <= matchThreshold
            && (subjectDistance.map { $0 <= subjectThreshold } ?? false)

        Self.logDistance(
            frame: frameDistance,
            subject: subjectDistance,
            matched: matched,
            lhs: lhs.assetID,
            rhs: rhs.assetID
        )

        return matched
    }

    /// Records every pair we considered and how far apart it scored.
    ///
    /// Thresholds for this kind of comparison can't be reasoned out from first principles — they
    /// depend on what's actually in a library. This exists so they can be set from the real
    /// distribution of distances on a device rather than guessed at. Only compiled into debug
    /// builds: it's a tuning aid, and logging every pair of a large library is not something a
    /// shipping app should do.
    private static func logDistance(
        frame: Double,
        subject: Double?,
        matched: Bool,
        lhs: String,
        rhs: String
    ) {
        #if DEBUG
        // Identifiers only — the log must never carry anything about the photos themselves.
        distanceLog.debug(
            """
            pair frame=\(frame, format: .fixed(precision: 4)) \
            subject=\(subject ?? -1, format: .fixed(precision: 4)) \
            matched=\(matched) \
            a=\(lhs.prefix(8), privacy: .public) b=\(rhs.prefix(8), privacy: .public)
            """
        )
        #endif
    }

    private static let distanceLog = Logger(
        subsystem: "com.rishichipra.slimline",
        category: "scan-distances"
    )
}
