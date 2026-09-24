import AVKit
import Photos
import SwiftUI

/// A flat multi-select grid. Used for screenshots, where there's no grouping to respect.
struct ScreenshotsView: View {
    let records: [AssetRecord]
    let sizesAreEstimated: Bool
    let plan: CleanPlan

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if sizesAreEstimated {
                    EstimatedSizeNotice()
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(records) { record in
                        SelectableAsset(
                            record: record,
                            isKeeper: false,
                            isSelected: plan.isSelected(record.id),
                            canSelect: true
                        ) {
                            plan.toggle(record)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Screenshots")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        plan.deselectAll(records)
                    } else {
                        plan.selectAll(records)
                    }
                }
                .disabled(records.isEmpty)
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No screenshots",
                    systemImage: "camera.viewfinder",
                    description: Text("You don't have any screenshots to clear out.")
                )
            }
        }
    }

    private var allSelected: Bool {
        !records.isEmpty && records.allSatisfy { plan.isSelected($0.id) }
    }
}

/// Videos, largest first, each with a preview.
struct LargeVideosView: View {
    let records: [AssetRecord]
    let plan: CleanPlan

    var body: some View {
        List {
            ForEach(records) { record in
                NavigationLink {
                    VideoPreviewView(record: record)
                } label: {
                    row(for: record)
                }
            }
        }
        .navigationTitle("Large Videos")
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No videos",
                    systemImage: "video.slash",
                    description: Text("There are no videos in your library.")
                )
            }
        }
    }

    private func row(for record: AssetRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                plan.toggle(record)
            } label: {
                Image(systemName: plan.isSelected(record.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(plan.isSelected(record.id) ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(plan.isSelected(record.id) ? "Selected for deletion" : "Not selected")

            AssetThumbnail(assetID: record.id, side: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.byteSize.map { ByteFormatting.string($0) } ?? "Size unknown")
                    .font(.body.weight(.medium))
                Text(durationText(record.duration))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
    }
}

/// Inline playback so the user can check what a video is before removing it.
struct VideoPreviewView: View {
    let record: AssetRecord

    @State private var player: AVPlayer?

    var body: some View {
        VStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Preview")
        .task { player = await Self.makePlayer(assetID: record.id) }
        .onDisappear { player?.pause() }
    }

    private static func makePlayer(assetID: String) async -> AVPlayer? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else { return nil }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .automatic

        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            let resumer = SingleResume(continuation)
            PHImageManager.default().requestPlayerItem(
                forVideo: asset,
                options: options
            ) { item, _ in
                resumer.resume(item)
            }
        }

        return item.map(AVPlayer.init(playerItem:))
    }
}
