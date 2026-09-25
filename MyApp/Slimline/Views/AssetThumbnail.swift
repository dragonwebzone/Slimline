import Photos
import SwiftUI

/// A thumbnail for one asset, loaded on demand.
///
/// Requests at the pixel size actually needed rather than full resolution — a grid of full-size
/// decodes is the fastest way to make a photo app stutter. Never fetches over the network, so
/// scrolling can't quietly pull originals from iCloud.
struct AssetThumbnail: View {
    let assetID: String
    /// Fixed square side. `nil` fills whatever space the parent gives, which is what the photo
    /// grid needs: its cards are 4:5, not square.
    var side: CGFloat?
    /// Pixel budget when filling. Ignored when `side` is set.
    var targetPixels: CGFloat = 220
    /// Zero when the parent already clips, so the corner isn't rounded twice.
    var cornerRadius: CGFloat = 8
    /// Crop to fill the frame, or show the whole image. Grids fill; a preview fits, because the
    /// point of a preview is seeing what's actually in the photo, including its edges.
    var fills: Bool = true

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fills ? .fill : .fit)
            } else {
                Rectangle()
                    .fill(Theme.surfaceDim)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(Theme.secondaryText)
                            .imageScale(.small)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: assetID) {
            image = await Self.load(
                assetID: assetID,
                pixels: (side ?? targetPixels) * displayScale
            )
        }
        .accessibilityHidden(true)
    }

    /// A thumbnail that fills a fixed aspect ratio without disturbing its neighbours.
    ///
    /// The obvious spelling — `.aspectRatio(ratio, contentMode: .fill)` on the image — is wrong in
    /// a grid: `.fill` grows the view *past* the size it was offered, so cells overlap each other.
    /// A transparent spacer takes the ratio with `.fit`, and the image fills and clips inside it.
    struct Filling: View {
        let assetID: String
        let ratio: CGFloat
        var targetPixels: CGFloat = 240

        var body: some View {
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    AssetThumbnail(
                        assetID: assetID,
                        targetPixels: targetPixels,
                        cornerRadius: 0
                    )
                }
                .clipped()
                .contentShape(.rect)
        }
    }

    private static func load(assetID: String, pixels: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        // High quality and exact sizing. `fastFormat` plus `fast` was fine when thumbnails were
        // 88pt squares, but the grid cells are now twice that and the difference reads as a
        // blurry image — which, in an app asking "is this one worth keeping?", defeats the point.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            let resumer = SingleResume(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixels, height: pixels),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                resumer.resume(image)
            }
        }
    }
}
