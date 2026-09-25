import SwiftUI

/// Explains why access is needed and handles every refusal state without dead-ending.
///
/// The brief calls out "denied" and "limited" specifically, so each state gets its own copy and
/// its own next action — never a blank screen.
struct PermissionGateView: View {
    let access: PhotoAccess
    let onRequest: () async -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)

            Text(explanation)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            action
                .frame(maxWidth: 260)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch access {
        case .notDetermined: "Let Slimline look at your photos"
        case .denied: "Photo access is off"
        case .restricted: "Photo access isn't available"
        case .limited, .full: "Ready to scan"
        }
    }

    private var explanation: String {
        switch access {
        case .notDetermined:
            "Slimline needs to read your library to find duplicates, screenshots and large videos. Everything happens on this iPhone, and nothing is deleted without your approval."
        case .denied:
            "Slimline can't find anything to clean without access to your photos. You can turn it back on in Settings."
        case .restricted:
            "Photo access is blocked on this iPhone, probably by Screen Time or a configuration profile, so Slimline can't scan your library."
        case .limited, .full:
            ""
        }
    }

    @ViewBuilder
    private var action: some View {
        switch access {
        case .notDetermined:
            PrimaryActionButton(title: "Continue") {
                Task { await onRequest() }
            }
        case .denied:
            PrimaryActionButton(title: "Open Settings", action: onOpenSettings)
        case .restricted, .limited, .full:
            EmptyView()
        }
    }
}

#Preview("Not determined") {
    PermissionGateView(access: .notDetermined, onRequest: {}, onOpenSettings: {})
}

#Preview("Denied") {
    PermissionGateView(access: .denied, onRequest: {}, onOpenSettings: {})
}
