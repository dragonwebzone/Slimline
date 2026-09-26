import Photos
import SwiftUI

/// Everything currently selected for deletion, as thumbnails, with a last chance to take any back.
///
/// The review screen used to show only a count. That asks the user to approve a number rather than
/// the photos behind it — and "Remove 49 items" is exactly the moment someone should be able to see
/// all 49. Tapping a photo here deselects it, and it stays on screen (unticked) so a mis-tap can be
/// undone on the spot rather than vanishing.
struct SelectedAssetsView: View {
    let plan: CleanPlan

    @State private var records: [AssetRecord] = []
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stillSelected) of \(records.count) selected")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text("Tap to keep one. Long-press to look closer.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Chip(text: ByteFormatting.string(plan.totalBytes))
                }
                .card(padding: 14)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(records) { record in
                        SelectedAssetCell(
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
        .navigationTitle("Selected")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "photo.on.rectangle",
                    description: Text("Photos and videos you select will appear here.")
                )
            }
        }
        // Loaded once on arrival and then held, so deselecting leaves the photo in place rather
        // than reflowing the grid under the user's finger.
        .task { records = Self.load(plan) }
    }

    private var stillSelected: Int {
        records.filter { plan.isSelected($0.id) }.count
    }

    /// Resolves the plan's identifiers back to records, largest first.
    ///
    /// The plan stores only identifiers and sizes, so the assets are re-fetched here. Anything
    /// that has since left the library simply doesn't come back, which is the right outcome — it
    /// can't be deleted either.
    static func load(_ plan: CleanPlan) -> [AssetRecord] {
        let ids = plan.selectedAssetIDs
        guard !ids.isEmpty else { return [] }

        var loaded: [AssetRecord] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            var record = AssetRecord(asset)
            // The plan's figure, not a fresh one: for a compressed video it's the net saving, and
            // this screen should agree with the total on the review screen.
            record.byteSize = plan.selectedAssets[asset.localIdentifier]
            loaded.append(record)
        }
        return loaded.sorted { ($0.byteSize ?? 0) > ($1.byteSize ?? 0) }
    }
}

/// A selected photo or video, with a video badge and a clear "kept" state once deselected.
private struct SelectedAssetCell: View {
    let record: AssetRecord
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AssetThumbnail.Filling(assetID: record.id, ratio: 1, targetPixels: 240)
                .overlay {
                    // Deselected photos dim and say so, so the grid reads as "these will go, these
                    // won't" at a glance.
                    if !isSelected {
                        Theme.background.opacity(0.55)
                        Text("Keep")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.surface, in: .capsule)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .clear)
                        .frame(width: 22, height: 22)
                        .background(isSelected ? Theme.destructive : Theme.surface, in: .circle)
                        .overlay(Circle().strokeBorder(isSelected ? Theme.destructive : Theme.divider, lineWidth: 1))
                        .padding(6)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 3) {
                        if let bytes = record.byteSize {
                            Text(ByteFormatting.string(bytes))
                        }
                        Spacer(minLength: 0)
                        if record.isVideo {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(6)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    )
                }
                .clipShape(.rect(cornerRadius: Theme.innerCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.innerCorner)
                        .strokeBorder(isSelected ? Theme.destructive : Theme.divider, lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .assetPreview(record, isSelected: isSelected, onToggle: onTap)
        .accessibilityLabel(isSelected ? "Will be removed" : "Will be kept")
        .accessibilityHint("Double-tap to change")
    }
}

/// A row of the first few selected thumbnails, for the review screen.
struct SelectedAssetsStrip: View {
    let plan: CleanPlan

    @State private var ids: [String] = []

    var body: some View {
        HStack(spacing: -10) {
            ForEach(ids, id: \.self) { id in
                AssetThumbnail(assetID: id, side: 40, cornerRadius: 10)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.surface, lineWidth: 2))
            }
            if plan.totalAssetCount > ids.count {
                Text("+\(plan.totalAssetCount - ids.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceDim, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.surface, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
        // Largest first, matching the full grid, so the strip shows what matters most.
        .task(id: plan.totalAssetCount) {
            ids = plan.selectedAssets.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        }
    }
}
