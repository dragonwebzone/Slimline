import Foundation
import Testing

@testable import MyApp

/// Tests for the blur verdict, on synthetic images.
///
/// The measure's whole job is telling "soft" from "sharp", and the cases that matter most are the
/// ones where the obvious approach gets it wrong: a sharp subject on a soft background, and a
/// featureless-but-sharp scene. Those are built directly as pixel buffers so the tests don't
/// depend on any photo library.
@Suite("Blur detection")
struct BlurDetectorTests {

    private let side = 64

    /// A checkerboard: maximum edges everywhere.
    private func checkerboard() -> [UInt8] {
        (0..<(side * side)).map { index in
            let x = index % side, y = index / side
            return (x / 4 + y / 4) % 2 == 0 ? 0 : 255
        }
    }

    /// A smooth left-to-right gradient: no edges at all, which is what a blurred photo looks like.
    private func gradient() -> [UInt8] {
        (0..<(side * side)).map { index in UInt8((index % side) * 255 / (side - 1)) }
    }

    @Test("A sharp image scores far higher than a soft one")
    func sharpBeatsSoft() {
        let sharp = BlurDetector.tiledSharpness(gray: checkerboard(), width: side, height: side)
        let soft = BlurDetector.tiledSharpness(gray: gradient(), width: side, height: side)

        #expect(sharp > BlurDetector.sharpnessThreshold * 10)
        #expect(soft < BlurDetector.sharpnessOnlyThreshold)
    }

    @Test("One sharp region is enough to count as sharp")
    func sharpSubjectOnSoftBackground() {
        // A portrait: the subject is in focus, the rest deliberately isn't. Averaging over the
        // whole frame would call this blurry; the sharpest-tile measure must not.
        var image = gradient()
        let board = checkerboard()
        for y in 0..<16 {
            for x in 0..<16 {
                image[y * side + x] = board[y * side + x]
            }
        }

        let score = BlurDetector.tiledSharpness(gray: image, width: side, height: side)

        #expect(score > BlurDetector.sharpnessThreshold)
    }

    @Test("A flat image is soft by measure alone")
    func flatImageHasNoEdges() {
        let flat = [UInt8](repeating: 128, count: side * side)

        #expect(BlurDetector.tiledSharpness(gray: flat, width: side, height: side) == 0)
    }

    @Test("Low sharpness alone doesn't condemn a photo when the model disagrees")
    func bothSignalsMustAgree() {
        // A clear sky: no edges, but not blurred. This is the false positive that requiring the
        // smudge model to agree exists to prevent.
        let sky = BlurDetector.Result(stamp: 0, sharpness: 5, smudge: 0.1)

        #expect(BlurDetector.isBlurry(sky) == false)
    }

    @Test("A confident smudge verdict alone doesn't condemn a sharp photo")
    func smudgeAloneIsNotEnough() {
        // Bokeh, or a long exposure: the model may think it's hazy, but part of it is sharp.
        let bokeh = BlurDetector.Result(stamp: 0, sharpness: 400, smudge: 0.95)

        #expect(BlurDetector.isBlurry(bokeh) == false)
    }

    @Test("Soft and hazy together is blurry")
    func agreementIsBlurry() {
        let shaken = BlurDetector.Result(stamp: 0, sharpness: 12, smudge: 0.9)

        #expect(BlurDetector.isBlurry(shaken))
    }

    @Test("Without the model, only very soft photos are flagged")
    func fallbackIsStricter() {
        let borderline = BlurDetector.Result(stamp: 0, sharpness: 30, smudge: nil)
        let clearlySoft = BlurDetector.Result(stamp: 0, sharpness: 8, smudge: nil)

        #expect(BlurDetector.isBlurry(borderline) == false)
        #expect(BlurDetector.isBlurry(clearlySoft))
    }

    @Test("Degenerate images don't crash")
    func tinyImagesAreSafe() {
        #expect(BlurDetector.tiledSharpness(gray: [0, 0, 0, 0], width: 2, height: 2) == 0)
    }
}
