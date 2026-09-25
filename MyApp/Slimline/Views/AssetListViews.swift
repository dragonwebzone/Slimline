import AVKit
import Photos
import SwiftUI

/// A flat multi-select grid. Used for screenshots, where there's no grouping to respect.
struct ScreenshotsView: View {
    let records: [AssetRecord]
    let sizesAreEstimated: Bool
    let plan: CleanPlan

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                summaryCard

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(records) { record in
                        GridPhotoCell(
                            record: record,
                            isSelected: plan.isSelected(record.id)
                        ) {
                            plan.toggle(record)
                        }
                    }
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No screenshots",
                    systemImage: "crop",
                    description: Text("You don't have any screenshots to clear out.")
                )
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading("Potential Recovery")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormatting.string(totalBytes))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text("recoverable")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: "\(records.count) items")
            }

            Text(
                sizesAreEstimated
                    ? "Screenshots are rarely worth keeping. Sizes are approximate on this version of iOS."
                    : "Screenshots are rarely worth keeping once you've acted on them."
            )
            .font(.system(size: 12))
            .foregroundStyle(sizesAreEstimated ? Theme.warning : Theme.secondaryText)

            Button {
                if allSelected {
                    plan.deselectAll(records)
                } else {
                    plan.selectAll(records)
                }
            } label: {
                Text(allSelected ? "Deselect all" : "Select all \(records.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Theme.background, in: .rect(cornerRadius: Theme.controlCorner))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.controlCorner)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(records.isEmpty)
        }
        .card()
    }

    private var totalBytes: Int64 {
        records.compactMap(\.byteSize).reduce(0, +)
    }

    private var allSelected: Bool {
        !records.isEmpty && records.allSatisfy { plan.isSelected($0.id) }
    }
}

/// One cell in a flat grid: thumbnail, size, selection state.
struct GridPhotoCell: View {
    let record: AssetRecord
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AssetThumbnail.Filling(assetID: record.id, ratio: 3 / 4, targetPixels: 240)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .clear)
                        .frame(width: 22, height: 22)
                        .background(isSelected ? Theme.accent : Theme.surface, in: .circle)
                        .overlay(
                            Circle().strokeBorder(
                                isSelected ? Theme.accent : Theme.divider,
                                lineWidth: 1
                            )
                        )
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if let bytes = record.byteSize {
                        Text(ByteFormatting.string(bytes))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.surface.opacity(0.92), in: .rect(cornerRadius: 4))
                            .padding(6)
                    }
                }
                .clipShape(.rect(cornerRadius: Theme.innerCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.innerCorner)
                        .strokeBorder(
                            isSelected ? Theme.accent : Theme.divider,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .assetPreview(record, isSelected: isSelected, onToggle: onTap)
        .accessibilityLabel(
            isSelected
                ? "Selected for deletion, \(record.byteSize.map { ByteFormatting.string($0) } ?? "size unknown")"
                : "Screenshot, \(record.byteSize.map { ByteFormatting.string($0) } ?? "size unknown")"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Screenshot grid layout") {
    // Real asset IDs aren't available in a preview, so the thumbnails render as placeholders.
    // What this verifies is the thing that was broken: that cells tile without overlapping.
    let records = (0..<9).map { index in
        AssetRecord(
            id: "preview-\(index)",
            creationDate: Date(),
            modificationDate: nil,
            pixelWidth: 1170,
            pixelHeight: 2532,
            isVideo: false,
            isScreenshot: true,
            isScreenRecording: false,
            duration: 0,
            isFavorite: false,
            hasAdjustments: false,
            byteSize: Int64(2_400_000 + index * 100_000)
        )
    }

    return NavigationStack {
        ScreenshotsView(records: records, sizesAreEstimated: false, plan: CleanPlan())
            .navigationTitle("Screenshots")
    }
}

/// Videos, largest first, each with a preview.
struct LargeVideosView: View {
    let records: [AssetRecord]
    let plan: CleanPlan

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    /// A grid, the way Photos shows videos, still ordered largest first.
    ///
    /// `LazyVGrid` defers building cells, which is what matters here — a plain stack built every
    /// row the instant the tab was selected and stalled it. Note the limit: lazy containers defer
    /// creation but don't recycle, so cells stay in memory once scrolled past. Fine for the
    /// hundreds of videos a phone holds; `List` would be the better call at thousands.
    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                summaryCard

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(records) { record in
                        VideoGridCell(record: record, plan: plan)
                    }
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "No videos",
                    systemImage: "play.slash",
                    description: Text("There are no videos in your library.")
                )
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading("Potential Recovery")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormatting.string(totalBytes))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text("recoverable")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: "\(records.count) items")
            }

            Text("Largest first. Tap to watch, or tap the circle to select.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .card()
    }

    private var totalBytes: Int64 {
        records.compactMap(\.byteSize).reduce(0, +)
    }
}

/// Sample videos for previews.
///
/// Built by an explicit function rather than inline in the `#Preview`: a `map` closure producing a
/// twelve-argument initialiser with arithmetic in it defeats the type checker outright.
private func previewVideos(count: Int) -> [AssetRecord] {
    var records: [AssetRecord] = []
    for index in 0..<count {
        let seconds: TimeInterval = 35 + Double(index) * 47
        let bytes: Int64 = 420_000_000 - Int64(index) * 60_000_000
        records.append(
            AssetRecord(
                id: "preview-video-\(index)",
                creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                modificationDate: nil,
                pixelWidth: 1920,
                pixelHeight: 1080,
                isVideo: true,
                isScreenshot: false,
                isScreenRecording: false,
                duration: seconds,
                isFavorite: false,
                hasAdjustments: false,
                byteSize: bytes
            )
        )
    }
    return records
}

#Preview("Video grid layout") {
    // Thumbnails render as placeholders without a real library; what this checks is the tiling,
    // the badge positions and that the selection control doesn't crowd the duration.
    NavigationStack {
        LargeVideosView(records: previewVideos(count: 6), plan: CleanPlan())
            .navigationTitle("Large Videos")
    }
}

/// One video in the grid.
///
/// Two targets rather than one, because a grid tile can't do both jobs from a single tap and both
/// jobs matter here: watching a video is how you decide, and selecting it is the decision. The
/// body opens playback; the circle selects. Splitting them keeps either action from being a
/// surprise.
private struct VideoGridCell: View {
    let record: AssetRecord
    let plan: CleanPlan

    private var isSelected: Bool { plan.isSelected(record.id) }

    var body: some View {
        NavigationLink {
            VideoPreviewView(record: record, plan: plan)
        } label: {
            AssetThumbnail.Filling(assetID: record.id, ratio: 1, targetPixels: 240)
                // A scrim under the badges, as Photos has. White-on-anything is only legible if
                // the anything is guaranteed dark, and a video's first frame may be a white wall.
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 44)
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .overlay(alignment: .bottomLeading) { sizeBadge }
                .overlay(alignment: .topTrailing) { selectionControl }
                .clipShape(.rect(cornerRadius: Theme.innerCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.innerCorner)
                        .strokeBorder(
                            isSelected ? Theme.accent : Theme.divider,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .assetPreview(record, isSelected: isSelected) { plan.toggle(record) }
        .accessibilityLabel(accessibilityLabel)
    }

    /// Play glyph and running time, bottom-right, as Photos does it.
    private var durationBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8))
            Text(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .padding(6)
    }

    /// Size sits opposite the duration, in white on the same scrim, so the two read as one strip
    /// rather than a chip competing with a label.
    private var sizeBadge: some View {
        Group {
            if let bytes = record.byteSize {
                Text(ByteFormatting.string(bytes))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
            }
        }
    }

    /// A deliberately generous tap target: a 22pt circle inside a 40pt hit area, so selecting
    /// doesn't turn into opening the video by accident.
    private var selectionControl: some View {
        Button {
            plan.toggle(record)
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isSelected ? .white : .clear)
                .frame(width: 22, height: 22)
                .background(isSelected ? Theme.accent : Theme.surface.opacity(0.92), in: .circle)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Theme.accent : Theme.divider,
                        lineWidth: 1
                    )
                )
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Selected for deletion" : "Select for deletion")
    }

    private var accessibilityLabel: String {
        let size = record.byteSize.map { ByteFormatting.string($0) } ?? "size unknown"
        let length = Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond))
        return "Video, \(length), \(size). Opens playback."
    }
}

/// Full-screen playback so the user can check what a video is before removing it.
///
/// Modelled on the Photos app viewer: black throughout, the video filling the screen, playback
/// starting on its own, and the capture date as the title. The app's warm palette is right for
/// browsing lists but wrong here — a cream surround changes how the footage itself reads, and the
/// whole question on this screen is what the footage looks like.
struct VideoPreviewView: View {
    let record: AssetRecord
    let plan: CleanPlan

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .horizontal)
            } else if failed {
                ContentUnavailableView(
                    "Can't play this video",
                    systemImage: "play.slash",
                    description: Text("It may still be stored in iCloud rather than on this iPhone.")
                )
            } else {
                ProgressView().tint(.white)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Dark chrome so the back button and title stay legible against the video.
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
        .safeAreaInset(edge: .bottom) { actionBar }
        .task {
            guard let made = await Self.makePlayer(assetID: record.id) else {
                failed = true
                return
            }
            player = made
            // Auto-play, like Photos. The user tapped a video to see it, not to find a play
            // button.
            made.play()
        }
        .onDisappear { player?.pause() }
    }

    /// The capture date, which is what Photos puts here. "Preview" told the user nothing they
    /// didn't already know from having tapped a video.
    private var title: String {
        record.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Video"
    }

    /// Facts and a decision, in reach while the video plays.
    ///
    /// Being able to act here is the point: having just watched it is exactly the moment someone
    /// knows whether they want it, and making them go back to the list to say so loses that.
    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.byteSize.map { ByteFormatting.string($0) } ?? "Size unknown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(durationText(record.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            let isSelected = plan.isSelected(record.id)
            Button {
                plan.toggle(record)
            } label: {
                Label(
                    isSelected ? "Keep" : "Select",
                    systemImage: isSelected ? "arrow.uturn.backward" : "trash"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(Theme.destructive),
                    in: .capsule
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.screenInset)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6))
    }

    private func durationText(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
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
