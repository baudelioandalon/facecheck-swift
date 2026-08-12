import Foundation
import XCTest

@testable import FaceCheck

/// Port of the Kotlin `LumaSamplingTest`.
///
/// The one that matters is ``testSubsamplingDoesNotChangeSharpness``. Android and
/// iOS used to compute sharpness separately, and the iOS copy read its Laplacian
/// neighbours a full sampling step away instead of one pixel away. That inflates
/// the variance by roughly the fourth power of the step, and since the step is
/// derived from the face box, the *same face at a different distance* scored
/// differently on the same phone. Nothing crashed and no test failed:
/// ``LivenessConfig/minSharpness`` simply stopped meaning anything on one of the
/// two platforms.
final class LumaSamplingTests: XCTestCase {

    // MARK: Test images

    /// A smooth ripple whose curvature — and therefore its Laplacian — is the
    /// same everywhere and at any region size. Measuring it densely and sparsely
    /// must give the same answer; that is the whole point.
    private func ripple(_ x: Int, _ y: Int) -> Int {
        Self.roundedToInt(128.0 + 120.0 * sin(Double(x) / 3.0) * sin(Double(y) / 3.0))
            .clamped(to: 0...255)
    }

    /// Uncorrelated pixel to pixel: as much fine detail as an image can hold.
    ///
    /// A checkerboard would be the obvious choice and is a trap — its period is
    /// 2, so any even sampling step lands on one colour and reports a *perfectly
    /// uniform* Laplacian. This is aliasing-proof.
    ///
    /// The Kotlin original relies on `Int` multiplication **overflowing**. Swift
    /// traps on that, so this uses `Int32` with the wrapping operators; the bit
    /// pattern, and therefore every value, is identical.
    private func fineDetail(_ x: Int, _ y: Int) -> Int {
        var h = Int32(truncatingIfNeeded: x) &* 374_761_393
            &+ Int32(truncatingIfNeeded: y) &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Int((h ^ (h >> 16)) & 0xFF)
    }

    /// A gentle ramp: real content, but nothing a Laplacian should call sharp.
    private func ramp(_ x: Int, _ y: Int) -> Int { ((x + y) / 8) % 256 }

    private func flat(_ level: Int) -> (Int, Int) -> Int { { _, _ in level } }

    /// Kotlin's `roundToInt()` is `floor(x + 0.5)`; Swift's `rounded()` breaks
    /// ties away from zero, which is a different pixel at every .5 boundary.
    private static func roundedToInt(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    // MARK: The regression tests

    func testSubsamplingDoesNotChangeSharpness() throws {
        // 48 px across: one sample per pixel, stencil and grid coincide.
        let dense = try XCTUnwrap(sampleLumaStats(left: 1, top: 1, right: 49, bottom: 49, luma: ripple))
        // 384 px across: the same 48 samples per axis, now eight pixels apart.
        let sparse = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 385, bottom: 385, luma: ripple)
        )

        XCTAssertEqual(dense.samples, sparse.samples, "both should take the same sample count")

        let ratio = sparse.sharpness / dense.sharpness
        XCTAssertTrue(
            ratio > 0.5 && ratio < 2,
            "sharpness must not scale with the sampling step: dense=\(dense.sharpness) "
                + "sparse=\(sparse.sharpness) (ratio \(ratio)). A stencil widened to the step "
                + "puts this in the hundreds."
        )
    }

    func testNeighboursAreReadOnePixelAway() {
        var asked = Set<[Int]>()
        _ = sampleLumaStats(left: 100, top: 100, right: 484, bottom: 484) { x, y in
            asked.insert([x, y])
            return self.ripple(x, y)
        }

        // The first centre is (100, 100) and the step is 8. Reading (99, 100)
        // proves the stencil is one pixel wide; never reading (92, 100) proves
        // it is not a step wide.
        XCTAssertTrue(asked.contains([99, 100]), "the west neighbour of the first centre")
        XCTAssertTrue(asked.contains([101, 100]), "the east neighbour of the first centre")
        XCTAssertTrue(asked.contains([100, 99]), "the north neighbour of the first centre")
        XCTAssertTrue(asked.contains([100, 101]), "the south neighbour of the first centre")
        XCTAssertFalse(
            asked.contains([92, 100]),
            "a neighbour a full step away was read; that measures a downscaled image"
        )
    }

    func testSharpnessIsIndependentOfWhereTheFaceSitsInTheFrame() throws {
        let corner = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 193, bottom: 193, luma: ripple)
        )
        let elsewhere = try XCTUnwrap(
            sampleLumaStats(left: 601, top: 401, right: 793, bottom: 593, luma: ripple)
        )
        XCTAssertLessThan(
            abs(corner.sharpness - elsewhere.sharpness),
            corner.sharpness * 0.5,
            "the same texture measured in two places gave \(corner.sharpness) and "
                + "\(elsewhere.sharpness)"
        )
    }

    // MARK: Ordering the estimator has to preserve

    func testSharpImagesOutscoreSmoothOnes() throws {
        let sharp = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 97, bottom: 97, luma: fineDetail)
        )
        let smooth = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 97, bottom: 97, luma: ramp)
        )
        let blank = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 97, bottom: 97, luma: flat(128))
        )

        XCTAssertGreaterThan(
            sharp.sharpness,
            smooth.sharpness,
            "fine detail should beat a ramp"
        )
        XCTAssertGreaterThanOrEqual(
            smooth.sharpness,
            blank.sharpness,
            "a ramp should not read softer than a flat field"
        )
        XCTAssertEqual(blank.sharpness, 0, accuracy: 0.001, "a flat field has no detail at all")
    }

    func testTheConfiguredBlurFloorSeparatesTheTwo() throws {
        // `LivenessConfig.minSharpness` is one number compared against whatever
        // either platform reports. A smear has to land below it and a detailed
        // face above it, or the `lowQuality` hint is decoration.
        let floor = LivenessConfig.default.minSharpness

        let blurred = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 193, bottom: 193) { x, y in
                // The same ripple stretched over forty pixels instead of three:
                // what a hand-shake smear leaves behind, where the Laplacian is
                // down in the quantisation noise.
                Self.roundedToInt(
                    128.0 + 100.0 * sin(Double(x) / 40.0) * sin(Double(y) / 40.0)
                )
            }
        )
        XCTAssertLessThan(
            blurred.sharpness,
            floor,
            "a near-flat gradient read as sharpness \(blurred.sharpness)"
        )

        let crisp = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 193, bottom: 193, luma: fineDetail)
        )
        XCTAssertGreaterThan(
            crisp.sharpness,
            floor,
            "a fully detailed image read as sharpness \(crisp.sharpness)"
        )
    }

    // MARK: Brightness

    func testBrightnessIsTheMeanOfTheSampledPixels() throws {
        let stats = try XCTUnwrap(
            sampleLumaStats(left: 0, top: 0, right: 64, bottom: 64, luma: flat(90))
        )
        XCTAssertEqual(stats.brightness, 90, accuracy: 0.001)
    }

    func testBrightnessTracksTheRectangleNotTheWholePlane() throws {
        // Dark on the left, blown out on the right. Only the rectangle decides,
        // which is why both platforms pass a face crop rather than the frame:
        // a backlit user has a fine *frame* average and an unusable face.
        let split: (Int, Int) -> Int = { x, _ in x < 100 ? 30 : 240 }
        let dark = try XCTUnwrap(
            sampleLumaStats(left: 1, top: 1, right: 65, bottom: 65, luma: split)
        )
        let bright = try XCTUnwrap(
            sampleLumaStats(left: 101, top: 1, right: 165, bottom: 65, luma: split)
        )
        XCTAssertEqual(dark.brightness, 30, accuracy: 0.001)
        XCTAssertEqual(bright.brightness, 240, accuracy: 0.001)
    }

    // MARK: Refusing to guess

    func testReturnsNilRatherThanMeasureTooFewPixels() {
        // Nine centres, below `minSamples`. A variance over that is noise, and
        // the callers report their neutral defaults instead of publishing it.
        XCTAssertNil(sampleLumaStats(left: 1, top: 1, right: 4, bottom: 4, luma: flat(120)))
    }

    func testReturnsNilWhenNoPixelIsReadable() {
        XCTAssertNil(sampleLumaStats(left: 0, top: 0, right: 200, bottom: 200) { _, _ in -1 })
    }

    func testDropsSamplesWhoseNeighboursAreUnreadable() throws {
        // A plane that refuses everything on its top row: those centres have no
        // usable stencil, so they must not reach the brightness average either.
        let stats = try XCTUnwrap(
            sampleLumaStats(left: 0, top: 0, right: 96, bottom: 96) { x, y in
                y <= 0 ? -1 : (x < 48 ? 40 : 200)
            }
        )
        XCTAssertEqual(stats.brightness, 120, accuracy: 0.001)
        XCTAssertGreaterThan(
            stats.samples,
            LumaSampling.minSamples,
            "should still have plenty of usable samples"
        )
    }

    func testRejectsEmptyOrInvertedRectangles() {
        XCTAssertNil(sampleLumaStats(left: 10, top: 10, right: 10, bottom: 40, luma: flat(120)))
        XCTAssertNil(sampleLumaStats(left: 10, top: 10, right: 40, bottom: 10, luma: flat(120)))
        XCTAssertNil(sampleLumaStats(left: 40, top: 40, right: 10, bottom: 10, luma: flat(120)))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
