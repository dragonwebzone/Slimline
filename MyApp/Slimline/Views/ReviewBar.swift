import SwiftUI

/// A persistent way to reach the review screen from wherever selections are made.
///
/// Selections happen on the category screens but the review step used to live only on the
/// dashboard, so the way to act on a selection was to tap Back and notice a button that hadn't
/// been there before. Nothing on screen said so. Since "scan, review, clean" is the whole point of
/// the app, the review step follows the user instead of waiting to be found.
///
/// Applied at the navigation call site rather than inside each category view, so those views stay
/// unaware of the deletion flow and keep taking nothing but a `CleanPlan`.
struct ReviewBar: ViewModifier {
    let plan: CleanPlan
    let sizesAreEstimated: Bool
    let onConfirm: () async -> Void

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if !plan.isEmpty {
                VStack(spacing: 8) {
                    summary
                    link
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background {
                    Theme.surface
                        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
                        .ignoresSafeArea(edges: .horizontal)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: plan.isEmpty)
    }

    /// The count on one side, the safety guarantee on the other.
    ///
    /// Restating that keepers are protected at the moment of commitment is worth the line: it's
    /// the single thing a user is most likely to be nervous about, and it's true by construction
    /// in `CleanPlan` rather than a claim the UI is making on its own.
    private var summary: some View {
        HStack(spacing: 6) {
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Label("Best shots protected", systemImage: "lock.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }

    private var link: some View {
        NavigationLink {
            ReviewView(
                plan: plan,
                sizesAreEstimated: sizesAreEstimated,
                onConfirm: onConfirm
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                Text("Review \(itemsPhrase)")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Theme.accent, in: .rect(cornerRadius: Theme.controlCorner))
        }
        .buttonStyle(.plain)
    }

    private var summaryText: String {
        // Only mentions bytes when there are any: a contacts-only selection frees nothing
        // measurable, and "Zero KB" beside a real selection reads like something went wrong.
        guard plan.totalBytes > 0 else { return "Selected: \(itemsPhrase)" }
        return "Selected: \(itemsPhrase) (\(ByteFormatting.string(plan.totalBytes)))"
    }

    private var itemCount: Int {
        plan.totalAssetCount + plan.totalContactsRemoved
    }

    private var itemsPhrase: String {
        "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    }
}

extension View {
    /// Shows the review bar whenever the plan holds anything.
    func reviewBar(
        plan: CleanPlan,
        sizesAreEstimated: Bool,
        onConfirm: @escaping () async -> Void
    ) -> some View {
        modifier(
            ReviewBar(plan: plan, sizesAreEstimated: sizesAreEstimated, onConfirm: onConfirm)
        )
    }
}
