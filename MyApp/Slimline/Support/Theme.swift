import SwiftUI
import UIKit

/// Slimline's visual identity: warm paper, deep green, hairline borders.
///
/// Deliberately not the blue-on-grey of a stock utility app, and deliberately not the reference
/// app's look either. Surfaces are flat and separated by borders rather than shadows, which keeps
/// dense screens — a grid of photos inside a group card inside a scroll view — legible without
/// stacking three levels of elevation.
///
/// Every colour carries a dark-mode counterpart. The identity is a light one, so the dark variants
/// keep the same warmth and the same green rather than falling back to system greys.
enum Theme {
    /// Page background. Warm off-white rather than pure grey.
    static let background = Color(light: 0xF6F4EF, dark: 0x161513)
    /// Cards and rows.
    static let surface = Color(light: 0xFFFFFF, dark: 0x21201D)
    /// Recessed fills: segmented controls, badges, thumbnails behind images.
    static let surfaceDim = Color(light: 0xEFECE6, dark: 0x2B2A26)
    /// Hairline borders, which do the work shadows would otherwise do.
    static let divider = Color(light: 0xE4E0D8, dark: 0x3A3833)

    static let primaryText = Color(light: 0x1C1B19, dark: 0xF2F0EB)
    static let secondaryText = Color(light: 0x6B6860, dark: 0x9E9A91)

    /// Deep green. Used for anything the app is confident about: keepers, selections, progress.
    static let accent = Color(light: 0x1F6F5C, dark: 0x3E9C84)
    /// Reserved strictly for removal. Nothing decorative is ever this colour.
    static let destructive = Color(light: 0xC8412D, dark: 0xE06550)
    /// Caveats and things worth a second look.
    static let warning = Color(light: 0xC98A1E, dark: 0xE0A63C)

    // MARK: - Metrics

    // Close to Apple's own: grouped-list cards sit near 20pt, controls and tiles near 12pt. The
    // shapes are continuous ("squircle") corners, SwiftUI's default, which is what makes them
    // read as Apple's rather than as plain rounded rectangles.
    static let cardCorner: CGFloat = 20
    static let controlCorner: CGFloat = 12
    static let innerCorner: CGFloat = 12

    static let screenInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let contentSpacing: CGFloat = 12
}

extension Color {
    /// A colour that resolves differently in light and dark mode, from two hex literals.
    ///
    /// Hex rather than an asset catalog entry so the whole palette is readable in one place — with
    /// twelve colours across two appearances, twenty-four JSON files would hide the design rather
    /// than document it.
    init(light: UInt32, dark: UInt32) {
        self.init(
            uiColor: UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Components

/// The standard card: flat surface, hairline border, soft continuous corners.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardCorner)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// Applies the app's page background, edge to edge.
    func pageBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

/// A small all-caps label above a figure or a group of rows.
struct SectionHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A bordered pill for counts and qualifiers — "84 sets", "99% similar", "Same phone number".
struct Chip: View {
    let text: String
    var tint: Color = Theme.secondaryText

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.background, in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
    }
}

/// The full-width commit button used for every destructive action.
struct PrimaryActionButton: View {
    let title: String
    var systemImage: String?
    var isBusy: Bool = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            // A capsule, like the prominent buttons across iOS 26.
            .background(
                role == .destructive ? Theme.destructive : Theme.accent,
                in: .capsule
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
