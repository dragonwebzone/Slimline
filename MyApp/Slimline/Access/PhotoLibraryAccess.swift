import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Our own view of photo-library permission, collapsed to the cases the UI actually branches on.
enum PhotoAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// The user picked specific photos. Every scan still works, but only over that subset, so the
    /// UI has to say so rather than implying the whole library was checked.
    case limited
    case full

    var canScan: Bool { self == .limited || self == .full }

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .full
        case .limited: self = .limited
        @unknown default: self = .denied
        }
    }
}

/// Owns photo-library authorization and keeps it current.
///
/// Deliberately uses `authorizationStatus(for:)` / `requestAuthorization(for:)`. The older
/// no-argument variants are unusable for this app: they report `.authorized` even when the user
/// only granted limited access, which would make us silently claim a full-library scan.
@Observable
final class PhotoLibraryAccess {
    private(set) var access: PhotoAccess

    init() {
        access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Re-reads status. Call on foreground: the user can change access in Settings at any time,
    /// including revoking it mid-session.
    func refresh() {
        access = PhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func request() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = PhotoAccess(status)
    }

    /// Lets someone on limited access widen the selection.
    ///
    /// We suppress the system's own once-per-launch prompt via
    /// `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` and present it from a visible button
    /// instead, so it arrives in response to a deliberate tap.
    func presentLimitedLibraryPicker() {
        guard access == .limited, let controller = Self.topViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static var topViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}
