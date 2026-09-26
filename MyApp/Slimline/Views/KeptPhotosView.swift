import Photos
import SwiftUI

/// Everything the user has kept for good, with a way to let any of it be suggested again.
///
/// Keeping hides a photo from every result, so without this screen a mis-swipe would be
/// permanent and invisible. Tapping marks photos; the button below brings the marked ones back.
struct KeptPhotosView: View {
    let kept: KeptPhotos
    let onShowAgain: ([String]) -> Void

    @State private var ids: [String] = []
    @State private var marked: Set<String> = []
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ids.count) kept")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                    Text("These are left out of every suggestion. Tap any you want Slimline to suggest again.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        KeptPhotoCell(assetID: id, isMarked: marked.contains(id)) {
                            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
                        }
                    }
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .navigationTitle("Kept Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !ids.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(marked.count == ids.count ? "Clear" : "Select all") {
                        marked = marked.count == ids.count ? [] : Set(ids)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !marked.isEmpty {
                PrimaryActionButton(
                    title: "Suggest \(marked.count) again",
                    systemImage: "eye"
                ) {
                    let released = Array(marked)
                    withAnimation(.snappy) {
                        ids.removeAll { marked.contains($0) }
                        marked.removeAll()
                    }
                    onShowAgain(released)
                }
                .padding(.horizontal, Theme.screenInset)
                .padding(.vertical, 10)
                .background(Theme.background)
            }
        }
        .overlay {
            if ids.isEmpty {
                ContentUnavailableView(
                    "Nothing kept",
                    systemImage: "eye.slash",
                    description: Text("Select photos and tap Keep, swipe right in swipe review, or long-press a photo to stop it being suggested.")
                )
            }
        }
        .task { ids = Self.load(kept.ids) }
    }

    /// Newest first, and only photos still in the library.
    static func load(_ ids: Set<String>) -> [String] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var loaded: [String] = []
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: options)
            .enumerateObjects { asset, _, _ in loaded.append(asset.localIdentifier) }
        return loaded
    }
}

private struct KeptPhotoCell: View {
    let assetID: String
    let isMarked: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AssetThumbnail.Filling(assetID: assetID, ratio: 1, targetPixels: 240)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "eye")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isMarked ? .white : .clear)
                        .frame(width: 22, height: 22)
                        .background(isMarked ? Theme.accent : Theme.surface, in: .circle)
                        .overlay(Circle().strokeBorder(isMarked ? Theme.accent : Theme.divider, lineWidth: 1))
                        .padding(6)
                }
                .clipShape(.rect(cornerRadius: Theme.innerCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.innerCorner)
                        .strokeBorder(isMarked ? Theme.accent : Theme.divider, lineWidth: isMarked ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMarked ? "Will be suggested again" : "Kept")
        .accessibilityHint("Double-tap to change")
    }
}
