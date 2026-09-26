import EventKit
import UIKit

/// Our own view of calendar permission, mirroring `ContactAccess`.
enum CalendarAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// Write-only access can add events but not read them, which is useless for finding old ones.
    /// Treated as its own state so the gate can say so rather than pretending access was refused.
    case writeOnly
    case full

    var canScan: Bool { self == .full }

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .writeOnly: self = .writeOnly
        case .fullAccess: self = .full
        @unknown default: self = .denied
        }
    }
}

/// Owns calendar authorization.
@Observable
final class CalendarAccessController {
    private(set) var access: CalendarAccess

    init() {
        access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
    }

    func refresh() {
        access = CalendarAccess(EKEventStore.authorizationStatus(for: .event))
    }

    func request() async {
        _ = try? await EKEventStore().requestFullAccessToEvents()
        refresh()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
