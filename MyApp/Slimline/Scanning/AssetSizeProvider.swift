import AVFoundation
import Photos

/// Resolves on-disk byte sizes for assets.
///
/// PhotoKit has no single reliable size property across OS versions, so this tries three routes
/// in order of fidelity and records which one was used — the UI marks estimated figures so we
/// never present a guess as a measurement.
actor AssetSizeProvider {
    enum Fidelity: Sendable {
        /// Read from the asset's own resource metadata.
        case exact
        /// Measured from the backing file on disk.
        case measured
        /// Derived from pixel dimensions. Approximate.
        case estimated
    }

    struct Size: Sendable {
        let bytes: Int64
        let fidelity: Fidelity
    }

    /// Resource metadata, when PhotoKit will tell us.
    ///
    /// `PHAssetResource.dataSize` is the clean answer but is iOS 27 and later only, so on iOS
    /// 18–26 we fall through to measuring or estimating rather than reaching for the
    /// `value(forKey: "fileSize")` KVC trick, which pokes at a private property.
    private nonisolated func resourceSize(for asset: PHAsset) -> Int64? {
        guard #available(iOS 27, *) else { return nil }

        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the current rendered resource, falling back to the original.
        let ordered = resources.sorted { lhs, _ in
            lhs.type == .fullSizePhoto || lhs.type == .fullSizeVideo
        }
        for resource in ordered {
            if let size = resource.dataSize, size > 0 {
                return Int64(size)
            }
        }
        return nil
    }

    /// For videos, the backing file is reachable and gives an exact figure.
    private nonisolated func measuredVideoSize(for asset: PHAsset) async -> Int64? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat

        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }

        guard let urlAsset = avAsset as? AVURLAsset else { return nil }
        let values = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    /// Last resort. HEIC lands around 0.3 bytes per pixel and H.264/HEVC video around 1 MB per
    /// second at 1080p; both are rough, which is exactly why this is labelled as estimated.
    private nonisolated func estimate(for record: AssetRecord) -> Int64 {
        if record.isVideo {
            return Int64(record.duration * 1_100_000)
        }
        return Int64(Double(record.pixelCount) * 0.3)
    }

    /// Resolves sizes for a batch, returning records with `byteSize` filled in.
    ///
    /// Batches the `PHAsset` lookup into a single fetch. Doing it per asset means one fetch per
    /// photo, which is the difference between a snappy scan and a visibly stalled one on a large
    /// library.
    ///
    /// Videos are measured one at a time because each needs an `AVAsset` round trip. That's
    /// acceptable because libraries hold far fewer videos than photos, and the exact figure
    /// matters most there — "largest videos" is meaningless if the sizes are guesses.
    func resolveSizes(for records: [AssetRecord]) async -> [AssetRecord] {
        guard !records.isEmpty else { return [] }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: records.map(\.id), options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }

        var resolved: [AssetRecord] = []
        resolved.reserveCapacity(records.count)

        for var record in records {
            guard let asset = assetsByID[record.id] else {
                // Asset has gone since indexing; keep it out of size totals entirely.
                record.byteSize = nil
                resolved.append(record)
                continue
            }

            if let bytes = resourceSize(for: asset) {
                record.byteSize = bytes
            } else if record.isVideo, let bytes = await measuredVideoSize(for: asset) {
                record.byteSize = bytes
            } else {
                record.byteSize = estimate(for: record)
            }
            resolved.append(record)
        }

        return resolved
    }

    func size(for record: AssetRecord) async -> Size {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil).firstObject else {
            return Size(bytes: estimate(for: record), fidelity: .estimated)
        }

        if let bytes = resourceSize(for: asset) {
            return Size(bytes: bytes, fidelity: .exact)
        }
        if record.isVideo, let bytes = await measuredVideoSize(for: asset) {
            return Size(bytes: bytes, fidelity: .measured)
        }
        return Size(bytes: estimate(for: record), fidelity: .estimated)
    }
}
