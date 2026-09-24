import SwiftUI

/// The "space freed" summary.
///
/// Reports what was actually removed, taken from the deletion outcome rather than from what was
/// requested — if the user declined the system alert, or an asset had already gone, this says so
/// instead of claiming a win.
struct ResultView: View {
    let outcome: DeletionService.Outcome
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: outcome.didAnything ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 56))
                .foregroundStyle(outcome.didAnything ? Theme.accent : .secondary)
                .accessibilityHidden(true)

            Text(headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            if outcome.didAnything {
                VStack(spacing: 6) {
                    Text(ByteFormatting.string(outcome.bytesPendingReclaim))
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.accent)
                    Text("will be reclaimed once you empty Recently Deleted")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .card()
            }

            if let failure = outcome.failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        guard outcome.didAnything else { return "Nothing was removed" }

        var parts: [String] = []
        if outcome.assetsDeleted > 0 {
            parts.append("\(outcome.assetsDeleted) item\(outcome.assetsDeleted == 1 ? "" : "s")")
        }
        if outcome.contactsDeleted > 0 {
            parts.append("\(outcome.contactsDeleted) contact\(outcome.contactsDeleted == 1 ? "" : "s")")
        }
        return "Removed \(parts.formatted(.list(type: .and)))"
    }
}

#Preview("Success") {
    ResultView(
        outcome: DeletionService.Outcome(
            assetsRequested: 42,
            assetsDeleted: 42,
            contactsDeleted: 0,
            bytesPendingReclaim: 2_300_000_000,
            failure: nil
        ),
        onDone: {}
    )
}

#Preview("Declined") {
    ResultView(
        outcome: DeletionService.Outcome(
            assetsRequested: 42,
            assetsDeleted: 0,
            contactsDeleted: 0,
            bytesPendingReclaim: 0,
            failure: "Nothing was deleted."
        ),
        onDone: {}
    )
}
