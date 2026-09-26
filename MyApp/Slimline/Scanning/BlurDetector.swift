import Accelerate
import CoreGraphics
import os
import Photos
import UIKit
import Vision

/// Finds photos that are out of focus or shaken.
///
/// Two independent signals, and a photo is only called blurry when both agree — the same lesson
/// the similar-photo threshold taught. Either signal alone produces false positives a user would
/// resent:
///
/// - **Edge sharpness** (variance of the Laplacian) is the classic measure, but it can't tell
///   "blurred" from "featureless": a clear blue sky or a plain wall has no edges either.
/// - **Vision's lens-smudge model** recognises haze and blur as a learned property of the image,
///   but Apple documents that it also flags intentional blur — bokeh, long exposures.
///
/// Where the two agree, the photo is both edgeless *and* looks blurred to a trained model, which
/// is a much stronger claim than either makes on its own.
actor BlurDetector {
    nonisolated struct Result: Codable, Sendable, Equatable {
        /// The asset's modification stamp when this was measured. An edit invalidates it.
        let stamp: Double
        /// The sharpest tile's Laplacian variance. Higher is sharper.
        let sharpness: Double
        /// Vision's smudge confidence, 0–1, where available.
        let smudge: Float?
    }

    nonisolated struct Progress: Sendable {
        let completed: Int
        let total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// Below this, even the sharpest part of the photo has almost no edges.
    ///
    /// A starting value, not a tuned one. Debug builds log every measurement so it can be set
    /// from a real library, as the similarity threshold was.
    nonisolated static let sharpnessThreshold: Double = 45
    /// With no smudge model to corroborate, demand a much lower sharpness before saying anything.
    nonisolated static let sharpnessOnlyThreshold: Double = 18
    nonisolated static let smudgeThreshold: Float = 0.7

    /// Large enough that ordinary soft focus survives downscaling. At the 224px used for feature
    /// prints, a few pixels of blur in a 12-megapixel original vanishes entirely.
    private let analysisSide: CGFloat = 512

    /// Four at a time, at background priority. With the model now skipped for sharp photos, each
    /// measurement is mostly a decode, and the priority is what keeps it from competing with the
    /// thumbnails the user is actually looking at.
    private let maxConcurrent = 4

    /// Measures every record that has no still-valid cached result.
    func analyse(
        _ records: [AssetRecord],
        cached: [String: Result],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async -> [String: Result] {
        var results: [String: Result] = [:]
        var pending: [AssetRecord] = []

        for record in records {
            let stamp = Self.stamp(for: record)
            if let hit = cached[record.id], hit.stamp == stamp {
                results[record.id] = hit
            } else {
                pending.append(record)
            }
        }

        let total = pending.count
        guard total > 0 else { return results }
        onProgress(Progress(completed: 0, total: total))

        var completed = 0
        var next = 0
        var lastReportedPercent = -1

        await withTaskGroup(of: (String, Result)?.self) { group in
            while next < pending.count, next < maxConcurrent {
                let record = pending[next]
                group.addTask { [weak self] in await self?.measure(record) }
                next += 1
            }

            while let finished = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }

                if let (id, result) = finished { results[id] = result }
                completed += 1
                // Whole-percent steps only: the progress feeds a property the root view reads, so
                // a per-photo report rebuilt the entire tab interface once per photo.
                let percent = completed * 100 / total
                if percent != lastReportedPercent || completed == total {
                    lastReportedPercent = percent
                    onProgress(Progress(completed: completed, total: total))
                }

                if next < pending.count {
                    let record = pending[next]
                    group.addTask { [weak self] in await self?.measure(record) }
                    next += 1
                }
            }
        }

        return results
    }

    /// The verdict.
    nonisolated static func isBlurry(_ result: Result) -> Bool {
        if let smudge = result.smudge {
            return result.sharpness < sharpnessThreshold && smudge >= smudgeThreshold
        }
        return result.sharpness < sharpnessOnlyThreshold
    }

    // MARK: - Measurement

    private func measure(_ record: AssetRecord) async -> (String, Result)? {
        guard let image = await thumbnail(for: record.id) else { return nil }

        let sharpness = Self.tiledSharpness(of: image)
        // A photo is only blurry if both signals agree, so the model is pointless for anything the
        // cheap measure already calls sharp — which is most of a library. Skipping it there is the
        // single biggest saving in the pass. A `nil` smudge on a sharp photo still reads as "not
        // blurry" in `isBlurry`, so the verdict is unchanged.
        let smudge: Float? = sharpness < Self.sharpnessThreshold
            ? await Self.smudgeConfidence(of: image)
            : nil

        let result = Result(stamp: Self.stamp(for: record), sharpness: sharpness, smudge: smudge)
        Self.log(result, id: record.id)
        return (record.id, result)
    }

    private nonisolated static func smudgeConfidence(of image: CGImage) async -> Float? {
        guard #available(iOS 26, *) else { return nil }
        return try? await DetectLensSmudgeRequest().perform(on: image).confidence
    }

    /// The Laplacian variance of the sharpest tile in a 4×4 grid.
    ///
    /// The maximum rather than the whole-image figure is what stops portraits being flagged: a
    /// sharp face against a deliberately soft background is a good photo, and averaging the two
    /// would call it blurry. A photo is only soft if *nothing* in it is sharp.
    nonisolated static func tiledSharpness(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        guard width > 8, height > 8 else { return 0 }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return 0 }

        return tiledSharpness(gray: pixels, width: width, height: height)
    }

    /// The same measure over a raw greyscale buffer, split out so it can be tested without images.
    ///
    /// Accelerate rather than a pixel loop. The loop was correct but ran unoptimised in debug
    /// builds — a quarter of a million pixels per photo, bounds-checked one at a time — which made
    /// it the slowest part of the pass. vImage does the convolution and vDSP the statistics,
    /// both vectorised regardless of build configuration.
    nonisolated static func tiledSharpness(gray: [UInt8], width: Int, height: Int, grid: Int = 4) -> Double {
        guard width > 2, height > 2, gray.count >= width * height else { return 0 }

        let count = width * height
        var source = [Float](repeating: 0, count: count)
        vDSP.convertElements(of: gray, to: &source)

        // 4-neighbour Laplacian: how sharply each pixel differs from those around it. Edges give
        // large values, smooth regions near zero. Edge-extended so borders don't read as edges.
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        var laplacian = [Float](repeating: 0, count: count)
        let status = source.withUnsafeMutableBufferPointer { src in
            laplacian.withUnsafeMutableBufferPointer { dst in
                var input = vImage_Buffer(
                    data: src.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride
                )
                var output = vImage_Buffer(
                    data: dst.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride
                )
                return vImageConvolve_PlanarF(
                    &input, &output, nil, 0, 0, kernel, 3, 3, 0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard status == kvImageNoError else { return 0 }

        let tileWidth = max(1, width / grid)
        let tileHeight = max(1, height / grid)
        var best: Double = 0

        laplacian.withUnsafeBufferPointer { values in
            var tileY = 0
            while tileY < height {
                var tileX = 0
                while tileX < width {
                    let x1 = min(width, tileX + tileWidth)
                    let y1 = min(height, tileY + tileHeight)
                    let rowLength = x1 - tileX

                    var sum: Float = 0
                    var sumSquares: Float = 0
                    for y in tileY..<y1 {
                        // Each row of a tile is contiguous, so vDSP can take it in one call.
                        let row = UnsafeBufferPointer(rebasing: values[(y * width + tileX)..<(y * width + x1)])
                        sum += vDSP.sum(row)
                        sumSquares += vDSP.sumOfSquares(row)
                    }

                    let samples = Double(rowLength * (y1 - tileY))
                    if samples > 0 {
                        let mean = Double(sum) / samples
                        best = max(best, Double(sumSquares) / samples - mean * mean)
                    }
                    tileX += tileWidth
                }
                tileY += tileHeight
            }
        }

        return best
    }

    private nonisolated func thumbnail(for assetID: String) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        // Never pulled from iCloud: nothing leaves, or arrives on, the device mid-scan.
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let side = analysisSide
        return await withCheckedContinuation { continuation in
            let resumer = SingleResume(continuation)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                resumer.resume(image?.cgImage)
            }
        }
    }

    nonisolated static func stamp(for record: AssetRecord) -> Double {
        record.modificationDate?.timeIntervalSince1970 ?? 0
    }

    private nonisolated static func log(_ result: Result, id: String) {
        #if DEBUG
        blurLog.debug(
            """
            blur sharpness=\(result.sharpness, format: .fixed(precision: 1)) \
            smudge=\(result.smudge ?? -1, format: .fixed(precision: 3)) \
            blurry=\(isBlurry(result)) a=\(id.prefix(8), privacy: .public)
            """
        )
        #endif
    }

    private nonisolated static let blurLog = Logger(
        subsystem: "com.rishichipra.slimline",
        category: "blur"
    )
}
