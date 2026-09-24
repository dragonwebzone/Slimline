import Photos
import SwiftUI

/// A square thumbnail for one asset, loaded on demand.
///
/// Requests at the pixel size actually needed rather than full resolution — a grid of full-size
/// decodes is the fastest way to make a photo app stutter. Never fetches over the network, so
/// scrolling can't quietly pull originals from iCloud.
struct AssetThumbnail: View {
    let assetID: String
    let side: CGFloat

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 8))
        .task(id: assetID) {
            image = await Self.load(assetID: assetID, side: side, scale: displayScale)
        }
        .accessibilityHidden(true)
    }

    private static func load(assetID: String, side: CGFloat, scale: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let pixels = side * scale
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
