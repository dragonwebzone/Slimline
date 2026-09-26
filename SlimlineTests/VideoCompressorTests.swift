import AVFoundation
import Testing

@testable import MyApp

/// Tests for the compression decisions that don't need a real video.
@Suite("Video compression")
struct VideoCompressorTests {

    @Test("4K footage is scaled to 1080p")
    func fourKDropsTo1080p() {
        #expect(VideoCompressor.preset(width: 3840, height: 2160) == AVAssetExportPresetHEVC1920x1080)
        // Portrait 4K is still 4K.
        #expect(VideoCompressor.preset(width: 2160, height: 3840) == AVAssetExportPresetHEVC1920x1080)
    }

    @Test("1080p and below keep their resolution")
    func smallFootageKeepsResolution() {
        #expect(VideoCompressor.preset(width: 1920, height: 1080) == AVAssetExportPresetHEVCHighestQuality)
        #expect(VideoCompressor.preset(width: 1280, height: 720) == AVAssetExportPresetHEVCHighestQuality)
    }

    @Test("The saving reported is the original minus the copy")
    func netSavingSubtractsTheCopy() {
        // Deleting the original frees its size, but the copy now occupies space too. Reporting
        // the full original would promise space that doesn't come back.
        let outcome = VideoCompressor.Outcome(
            newAssetID: "copy",
            originalBytes: 600_000_000,
            compressedBytes: 180_000_000
        )

        #expect(outcome.netSaving == 420_000_000)
    }

    @Test("A net saving is never negative")
    func netSavingFloorsAtZero() {
        let outcome = VideoCompressor.Outcome(
            newAssetID: "copy",
            originalBytes: 100,
            compressedBytes: 200
        )

        #expect(outcome.netSaving == 0)
    }
}
