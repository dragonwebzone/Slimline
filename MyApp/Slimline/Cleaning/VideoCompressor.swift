import AVFoundation
import Photos

/// Re-encodes a video to a smaller file and saves the result alongside the original.
///
/// It never touches the original. Compression is lossy, so the order is: make the copy, save it
/// to the library, and only then offer the original for deletion — through the same review screen
/// as everything else. If anything fails partway, the user still has the video they started with.
actor VideoCompressor {
    enum Failure: LocalizedError {
        case unavailable
        case noMeaningfulSaving(original: Int64, compressed: Int64)
        case exportFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "This video isn't stored on this iPhone, so it can't be compressed. It may be in iCloud only."
            case .noMeaningfulSaving:
                "This video is already efficiently encoded — a compressed copy wouldn't be meaningfully smaller."
            case .exportFailed:
                "The video couldn't be compressed."
            case .saveFailed:
                "The compressed copy couldn't be saved to your library. Nothing was changed."
            }
        }
    }

    nonisolated struct Outcome: Sendable {
        let newAssetID: String
        let originalBytes: Int64
        let compressedBytes: Int64

        /// What deleting the original will actually free, now that a copy exists.
        var netSaving: Int64 { max(0, originalBytes - compressedBytes) }
    }

    /// Below this ratio of the original there's no point: the copy is lossy, and saving 5% isn't
    /// worth a generation of quality.
    nonisolated static let minimumSavingRatio = 0.85

    /// The preset: HEVC throughout, scaled to 1080p if the source is larger.
    ///
    /// 4K is where most of the space goes on a modern iPhone, and 1080p is where most people watch
    /// back their own footage. Anything already at 1080p or below keeps its resolution and gains
    /// only from HEVC's better compression.
    nonisolated static func preset(width: Int, height: Int) -> String {
        max(width, height) > 1920 ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPresetHEVCHighestQuality
    }

    func compress(
        _ record: AssetRecord,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Outcome {
        guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil).firstObject,
              let source = await Self.avAsset(for: original)
        else { throw Failure.unavailable }

        let presetName = Self.preset(width: record.pixelWidth, height: record.pixelHeight)
        guard let session = AVAssetExportSession(asset: source, presetName: presetName) else {
            throw Failure.exportFailed
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: output) }

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await session.export(to: output, as: .mov)
        } catch {
            throw Failure.exportFailed
        }

        let compressedBytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let originalBytes = record.byteSize ?? 0

        // Checked before saving, so an unhelpful copy never lands in the library at all.
        guard compressedBytes > 0,
              originalBytes == 0 || Double(compressedBytes) < Double(originalBytes) * Self.minimumSavingRatio
        else {
            throw Failure.noMeaningfulSaving(original: originalBytes, compressed: compressedBytes)
        }

        let newID = try await save(output, from: original)
        return Outcome(newAssetID: newID, originalBytes: originalBytes, compressedBytes: compressedBytes)
    }

    /// Adds the copy to the library, carrying across what makes it the same memory: when and where
    /// it was taken, and whether it was a favourite. Without the date it would sort as "today" and
    /// vanish from where the user expects to find it.
    private func save(_ url: URL, from original: PHAsset) async throws -> String {
        let created = CreatedID()
        let date = original.creationDate
        let location = original.location
        let favourite = original.isFavorite

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .video, fileURL: url, options: options)
                request.creationDate = date
                request.location = location
                request.isFavorite = favourite
                created.value = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw Failure.saveFailed
        }

        guard let id = created.value else { throw Failure.saveFailed }
        return id
    }

    private static func avAsset(for asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        // Never pulled from iCloud. Compressing a cloud-only video would mean downloading it, which
        // is exactly the kind of network traffic this app promises not to create.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return await withCheckedContinuation { continuation in
            let resumer = SingleResume(continuation)
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                resumer.resume(avAsset)
            }
        }
    }
}

/// Carries the new asset's identifier out of PhotoKit's change block, which is `@Sendable` and so
/// can't write to a local. `nonisolated` because the target defaults to main-actor isolation, and
/// this is written from that block, which runs off the main actor.
private nonisolated final class CreatedID: @unchecked Sendable {
    var value: String?
}
