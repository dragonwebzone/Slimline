import SwiftUI

/// Compresses one video, then offers the original for deletion.
///
/// Explicit about the trade before anything happens: compression is lossy, the copy lands next to
/// the original, and the original only goes if the user then approves it through review. The
/// sheet never deletes anything itself.
struct CompressVideoSheet: View {
    let record: AssetRecord
    let plan: CleanPlan
    /// Called once a copy has been saved, so the library can be rescanned to pick it up.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase = Phase.ready
    private let compressor = VideoCompressor()

    private enum Phase {
        case ready
        case compressing(Double)
        case done(VideoCompressor.Outcome)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                AssetThumbnail(assetID: record.id, side: 120, cornerRadius: Theme.cardCorner)
                    .overlay(alignment: .bottomTrailing) {
                        Text(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6)
                    }

                content

                Spacer(minLength: 0)

                action
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageBackground()
            .navigationTitle("Compress Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isCompressing ? "Cancel" : "Close") { dismiss() }
                }
            }
            .interactiveDismissDisabled(isCompressing)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            VStack(spacing: 10) {
                Text(record.byteSize.map { ByteFormatting.string($0) } ?? "Size unknown")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(resolutionNote)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                Text("A smaller copy is saved next to the original. The original is only removed if you then approve it in Review.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

        case .compressing(let fraction):
            VStack(spacing: 10) {
                Text("Compressing…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                ProgressView(value: fraction).tint(Theme.accent)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
            }

        case .done(let outcome):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)
                HStack(spacing: 8) {
                    Text(ByteFormatting.string(outcome.originalBytes))
                        .strikethrough()
                        .foregroundStyle(Theme.secondaryText)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(Theme.secondaryText)
                    Text(ByteFormatting.string(outcome.compressedBytes))
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.primaryText)
                }
                .font(.system(size: 20))
                Text("Copy saved to your library. The original is selected — review to free \(ByteFormatting.string(outcome.netSaving)).")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch phase {
        case .ready, .failed:
            PrimaryActionButton(title: "Compress", systemImage: "arrow.down.right.and.arrow.up.left") {
                start()
            }
        case .compressing:
            EmptyView()
        case .done:
            PrimaryActionButton(title: "Done") { dismiss() }
        }
    }

    private var isCompressing: Bool {
        if case .compressing = phase { return true }
        return false
    }

    private var resolutionNote: String {
        let longest = max(record.pixelWidth, record.pixelHeight)
        return longest > 1920
            ? "Re-encoded to 1080p HEVC. Resolution drops from \(longest > 3000 ? "4K" : "\(longest)p"), which is where most of the saving comes from."
            : "Re-encoded as HEVC at the same resolution."
    }

    private func start() {
        phase = .compressing(0)
        Task {
            do {
                let outcome = try await compressor.compress(record) { fraction in
                    Task { @MainActor in
                        if case .compressing = phase { phase = .compressing(fraction) }
                    }
                }

                // The original is selected at its *net* saving, not its full size: a copy now
                // exists, so the review screen claiming the whole original would overstate what
                // deleting it frees.
                var original = record
                original.byteSize = outcome.netSaving
                plan.select(original)

                phase = .done(outcome)
                onSaved()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
