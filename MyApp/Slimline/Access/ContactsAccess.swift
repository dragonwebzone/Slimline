import Contacts
import SwiftUI
import UIKit

/// Our own view of contacts permission, mirroring `PhotoAccess`.
enum ContactAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// The user shared specific contacts. We can read and modify only those, so a duplicate scan
    /// over this subset is genuinely partial and must be labelled that way.
    case limited
    case full

    var canScan: Bool { self == .limited || self == .full }

    init(_ status: CNAuthorizationStatus) {
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

/// Owns contacts authorization.
@Observable
final class ContactsAccess {
    private(set) var access: ContactAccess

    private let store = CNContactStore()

    init() {
        access = ContactAccess(CNContactStore.authorizationStatus(for: .contacts))
    }

    func refresh() {
        access = ContactAccess(CNContactStore.authorizationStatus(for: .contacts))
    }

    func request() async {
        // The granted/denied Bool can't distinguish full from limited, so re-read the status
        // afterwards rather than inferring it from the return value.
        _ = try? await store.requestAccess(for: .contacts)
        refresh()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
