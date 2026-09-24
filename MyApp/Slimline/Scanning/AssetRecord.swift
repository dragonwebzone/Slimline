import Photos

/// A small, `Sendable` snapshot of one photo or video.
///
/// `PHAsset` itself is a reference type we don't want to hand across isolation boundaries, so the
/// whole pipeline works on these records instead and re-fetches the real asset by
/// `localIdentifier` only at the moment of deletion. That also means a stale record can never
/// cause the wrong thing to be deleted — the re-fetch either finds the asset or it doesn't.
/// `nonisolated` because this target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: without
/// it, even a plain `Sendable` struct's members are main-actor-isolated and unreadable from the
/// scanner actors that do all the real work.
nonisolated struct AssetRecord: Sendable, Identifiable, Hashable {
    /// The asset's `localIdentifier`.
    let id: String
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isVideo: Bool
    let isScreenshot: Bool
    let isScreenRecording: Bool
    let duration: TimeInterval
    let isFavorite: Bool
    let hasAdjustments: Bool

    /// Bytes on disk. `nil` until resolved; see `AssetSizeProvider`.
    var byteSize: Int64?

    /// Quantised aspect ratio, used to bucket candidates before any expensive comparison.
    /// Rounded so that trivially different crops still land together.
    var aspectBucket: Int {
        guard pixelHeight > 0 else { return 0 }
        return Int((Double(pixelWidth) / Double(pixelHeight) * 20).rounded())
    }

    var pixelCount: Int { pixelWidth * pixelHeight }

    /// Memberwise init, used by tests to build records without a photo library.
    ///
    /// Declaring `init(_ asset:)` suppresses the synthesized one, and the grouping logic is only
    /// testable if records can be constructed from nothing.
    init(
        id: String,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        isVideo: Bool,
        isScreenshot: Bool,
        isScreenRecording: Bool,
        duration: TimeInterval,
        isFavorite: Bool,
        hasAdjustments: Bool,
        byteSize: Int64?
    ) {
        self.id = id
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isVideo = isVideo
        self.isScreenshot = isScreenshot
        self.isScreenRecording = isScreenRecording
        self.duration = duration
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
        self.byteSize = byteSize
    }

    init(_ asset: PHAsset) {
        id = asset.localIdentifier
        creationDate = asset.creationDate
        modificationDate = asset.modificationDate
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        isVideo = asset.mediaType == .video
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        isScreenRecording = asset.mediaSubtypes.contains(.videoScreenRecording)
        duration = asset.duration
        isFavorite = asset.isFavorite
        hasAdjustments = asset.hasAdjustments
        byteSize = nil
    }
}
