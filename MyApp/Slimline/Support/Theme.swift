import SwiftUI

/// Slimline's own visual identity — deliberately not modelled on the reference app.
enum Theme {
    /// A cool slate blue: reads as "system utility" rather than "aggressive cleaner".
    static let accent = Color(red: 0.24, green: 0.47, blue: 0.78)

    /// Used for the portion of the storage bar that a clean would reclaim.
    static let reclaimable = Color(red: 0.95, green: 0.64, blue: 0.24)

    static let cardCorner: CGFloat = 16
}

/// Standard card treatment for dashboard sections.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.cardCorner))
    }
}

extension View {
    func card() -> some View {
        modifier(CardBackground())
    }
}
