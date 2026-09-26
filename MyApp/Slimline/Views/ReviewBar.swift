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

    @Environment(\.keepForGood) private var keepForGood

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if !plan.isEmpty {
                VStack(spacing: 8) {
                    summary
                    HStack(spacing: 8) {
                        keepButton
                        link
                    }
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
    /// Restating that photos can be recovered at the moment of commitment is worth the line: it's
    /// the single thing a user is most likely to be nervous about.
    private var summary: some View {
        HStack(spacing: 6) {
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Label("Recoverable for 30 days", systemImage: "arrow.uturn.backward.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }

    /// The other thing to do with a selection: keep it, for good.
    ///
    /// Selecting is how several photos are picked at once, so the choice of what happens to them
    /// belongs here rather than in a separate multi-select mode. Keeping needs no review screen —
    /// nothing is deleted, and anything kept can be brought back from Kept Photos.
    @ViewBuilder
    private var keepButton: some View {
        if let keepForGood, plan.totalAssetCount > 0 {
            Button {
                withAnimation(.snappy) { keepForGood(plan.selectedAssetIDs) }
            } label: {
                Label("Keep \(plan.totalAssetCount)", systemImage: "eye.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(Theme.accent.opacity(0.12), in: .capsule)
                    .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1) }
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep \(plan.totalAssetCount) selected and don't show them again")
            .transition(.opacity)
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
            .frame(height: 50)
            .background(Theme.accent, in: .capsule)
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
        plan.totalItemCount
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
