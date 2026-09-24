import Photos

/// One pass over the photo library, producing `AssetRecord`s for everything downstream.
///
/// `PHFetchResult` is lazy, so enumerating it is cheap even on a very large library — the cost
/// is in resolving sizes and thumbnails, which happens later and on demand.
actor AssetIndex {
    /// Every photo and video we can see, newest first.
    func fetchAll() -> [AssetRecord] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Anything the user hid in Photos is none of our business.
        options.includeHiddenAssets = false

        return records(from: PHAsset.fetchAssets(with: options))
    }

    /// Screenshots, via the system smart album.
    ///
    /// Falls back to a media-subtype scan because the smart album is absent on libraries that
    /// have never contained a screenshot, and we'd rather return an empty list than nil.
    func fetchScreenshots() -> [AssetRecord] {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenshots,
            options: nil
        )

        if let album = albums.firstObject {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = records(from: PHAsset.fetchAssets(in: album, options: options))
            if !result.isEmpty { return result }
        }

        return fetchAll().filter(\.isScreenshot)
    }

    /// Videos, including screen recordings. Caller sorts by size once sizes are resolved.
    func fetchVideos() -> [AssetRecord] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        return records(from: PHAsset.fetchAssets(with: .video, options: options))
    }

    private func records(from result: PHFetchResult<PHAsset>) -> [AssetRecord] {
        var records: [AssetRecord] = []
        records.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            records.append(AssetRecord(asset))
        }
        return records
    }
}
