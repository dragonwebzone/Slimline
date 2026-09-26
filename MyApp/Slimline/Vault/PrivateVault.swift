import AVFoundation
import Foundation
import ImageIO
import LocalAuthentication
import Photos
import UIKit

/// One item in the vault.
nonisolated struct VaultItem: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let isVideo: Bool
    let bytes: Int64
    /// When the photo was taken, carried across so restoring puts it back in the right place.
    let originalDate: Date?
    let addedAt: Date
    /// The library asset it came from, so the original can be offered for deletion.
    let sourceAssetID: String?
}

/// Photos and videos copied out of the library into Slimline's own protected storage.
///
/// Where the data lives is the whole design, so it's worth being exact:
///
/// - **In the app's container, with `.complete` file protection** — encrypted by iOS whenever the
///   phone is locked, and unreadable by anything but Slimline.
/// - **Excluded from backup.** The brief is that nothing leaves the device, and an iCloud backup
///   is leaving the device. The cost is real and the UI says so: deleting the app deletes the
///   vault, and a new phone won't have it.
/// - **Copied, never moved.** Adding to the vault leaves the original in the library; removing the
///   original is a separate decision that goes through the normal review screen. If the copy
///   somehow failed, the user has lost nothing.
actor PrivateVault {
    enum Failure: LocalizedError {
        case unavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: "That item isn't stored on this iPhone, so it can't be added. It may be in iCloud only."
            case .writeFailed: "The item couldn't be saved to the vault."
            }
        }
    }

    private let directory: URL
    private let indexURL: URL
    private var items: [VaultItem]?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Vault", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
    }

    // MARK: - Reading

    func all() -> [VaultItem] {
        loadedItems().sorted { $0.addedAt > $1.addedAt }
    }

    func url(for item: VaultItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    // MARK: - Adding

    /// Copies one library asset into the vault.
    func add(assetID: String) async throws -> VaultItem {
        try prepareDirectory()

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let resource = Self.primaryResource(for: asset)
        else { throw Failure.unavailable }

        let ext = (resource.originalFilename as NSString).pathExtension
        let fileName = "\(UUID().uuidString).\(ext.isEmpty ? (asset.mediaType == .video ? "mov" : "jpg") : ext)"
        let destination = directory.appendingPathComponent(fileName)

        let options = PHAssetResourceRequestOptions()
        // Never pulled from iCloud: a cloud-only photo can't be vaulted without a download, and
        // downloading is traffic this app doesn't create.
        options.isNetworkAccessAllowed = false

        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
            try protect(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.writeFailed
        }

        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let item = VaultItem(
            id: UUID(),
            fileName: fileName,
            isVideo: asset.mediaType == .video,
            bytes: bytes,
            originalDate: asset.creationDate,
            addedAt: .now,
            sourceAssetID: asset.localIdentifier
        )

        var current = loadedItems()
        current.append(item)
        try save(current)
        return item
    }

    // MARK: - Leaving the vault

    /// Puts a copy back into the photo library, with its original date. The vault copy stays
    /// until the user removes it, so a failed restore loses nothing.
    func restore(_ item: VaultItem) async throws {
        let source = url(for: item)
        let date = item.originalDate
        let isVideo = item.isVideo

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: isVideo ? .video : .photo, fileURL: source, options: options)
            request.creationDate = date
        }
    }

    func remove(_ item: VaultItem) throws {
        try? FileManager.default.removeItem(at: url(for: item))
        try save(loadedItems().filter { $0.id != item.id })
    }

    // MARK: - Thumbnails

    /// A small image for the grid, decoded straight from the file without loading the full photo.
    nonisolated func thumbnail(for item: VaultItem, url: URL, maxPixel: CGFloat) async -> UIImage? {
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            guard let image = try? await generator.image(at: .zero).image else { return nil }
            return UIImage(cgImage: image)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    // MARK: - Storage

    private func loadedItems() -> [VaultItem] {
        if let items { return items }
        let decoded = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([VaultItem].self, from: $0) } ?? []
        items = decoded
        return decoded
    }

    private func save(_ updated: [VaultItem]) throws {
        items = updated
        let data = try JSONEncoder().encode(updated)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var folder = directory
        try exclude(&folder)
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var file = url
        try exclude(&file)
    }

    /// Keeps the vault out of iCloud and computer backups, so nothing in it leaves the device.
    private func exclude(_ url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// The resource that matches what the user sees: the edited version if there is one, since
    /// vaulting a photo and getting back the unedited original would be a surprise.
    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }
}

/// Face ID, falling back to the device passcode.
///
/// `.deviceOwnerAuthentication` rather than biometrics-only, so a user without Face ID set up — or
/// whose face isn't recognised — can still get in with their passcode. That's the PIN, and it's
/// the device's own rather than a second one the user would have to remember.
enum VaultLock {
    static func unlock() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your private vault"
            )
        } catch {
            return false
        }
    }

    /// "Face ID", "Touch ID" or "Passcode", for button labels.
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }
}
