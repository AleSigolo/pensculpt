import XCTest
@testable import PenSculpt

final class PartExtractorTests: XCTestCase {

    private func makeStroke(points: [CGPoint]) -> Stroke {
        Stroke(points: points.enumerated().map { i, p in
            StrokePoint(location: p, pressure: 1, tilt: 0, azimuth: 0,
                        timestamp: TimeInterval(i) * 0.01)
        })
    }

    /// `sweep` < 2π leaves a gap between the endpoints.
    private func circlePoints(center: CGPoint, radius: CGFloat,
                              sweep: CGFloat = 2 * CGFloat.pi,
                              steps: Int = 64) -> [CGPoint] {
        (0...steps).map { i in
            let angle = sweep * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: center.x + radius * cos(angle),
                           y: center.y + radius * sin(angle))
        }
    }

    func testClosedCircleBecomesPart() {
        let stroke = makeStroke(points: circlePoints(center: CGPoint(x: 100, y: 100), radius: 50))
        let parts = PartExtractor.parts(from: [stroke])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].sourceStrokeID, stroke.id)
        XCTAssertGreaterThanOrEqual(parts[0].contour.count, 3)
        // Pins the implicitly-closed contract: extraction must not append a closing point
        XCTAssertEqual(parts[0].contour.count, stroke.points.count)
    }

    func testOpenLineIsNotAPart() {
        let stroke = makeStroke(points: (0...50).map { CGPoint(x: CGFloat($0) * 4, y: 100) })
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testNearlyClosedArcBecomesPart() {
        // 350° of an r=50 circle: gap ≈ 8.7, arc ≈ 305 → ratio ≈ 0.03 → closes
        let stroke = makeStroke(points: circlePoints(
            center: CGPoint(x: 100, y: 100), radius: 50,
            sweep: 2 * CGFloat.pi * 350 / 360))
        XCTAssertEqual(PartExtractor.parts(from: [stroke]).count, 1)
    }

    func testHalfCircleIsNotAPart() {
        // 180°: gap = 100 (the diameter), arc ≈ 157 → ratio ≈ 0.64 → open
        let stroke = makeStroke(points: circlePoints(
            center: CGPoint(x: 100, y: 100), radius: 50, sweep: CGFloat.pi))
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testZeroAreaScribbleIsNotAPart() {
        // Out and back along the same line: gap 0, but |signed area| ≈ 0
        var pts = (0...25).map { CGPoint(x: CGFloat($0) * 4, y: 100) }
        pts += (0...25).reversed().map { CGPoint(x: CGFloat($0) * 4, y: 100) }
        let stroke = makeStroke(points: pts)
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testTinyStrokeIsNotAPart() {
        let stroke = makeStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testMixedStrokesOnlyClosedBecomeParts() {
        let closed = makeStroke(points: circlePoints(center: CGPoint(x: 100, y: 100), radius: 40))
        let open = makeStroke(points: (0...50).map { CGPoint(x: CGFloat($0) * 4, y: 300) })
        let parts = PartExtractor.parts(from: [closed, open])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].sourceStrokeID, closed.id)
    }

    // MARK: - Child-friendly closure (anchored appendages)

    func testSmallAbsoluteGapClosesEvenWhenRatioRejects() {
        // 270° of an r=20 circle: gap ≈ 28pt, arc ≈ 94 → ratio limit ≈ 19
        // rejects, but a ~28pt gap on a hand-drawn shape reads as closed to
        // the target user (an 8-year-old). The absolute tolerance accepts it.
        let stroke = makeStroke(points: circlePoints(
            center: CGPoint(x: 100, y: 100), radius: 20,
            sweep: 2 * CGFloat.pi * 270 / 360))
        XCTAssertEqual(PartExtractor.parts(from: [stroke]).count, 1)
    }

    func testAnchoredOpenAppendageBecomesPart() {
        // A "Λ" horn leaning on a closed head — the natural way appendages
        // are drawn. Both endpoints rest on the head's ink, so the appendage
        // closes with its implicit end-to-end edge and inflates as a part
        // (smooth-max union blends it into the host).
        let head = makeStroke(points: circlePoints(center: CGPoint(x: 150, y: 150), radius: 60))
        let horn = makeStroke(points: [CGPoint(x: 120, y: 100), CGPoint(x: 135, y: 60),
                                       CGPoint(x: 150, y: 30), CGPoint(x: 165, y: 60),
                                       CGPoint(x: 180, y: 100)])
        let parts = PartExtractor.parts(from: [head, horn])
        XCTAssertEqual(parts.count, 2, "the anchored horn must become a part")
        XCTAssertTrue(parts.contains { $0.sourceStrokeID == horn.id })
    }

    func testFloatingOpenAppendageStaysDecoration() {
        // The same Λ far from any ink: nothing anchors it — stays flat.
        let head = makeStroke(points: circlePoints(center: CGPoint(x: 150, y: 150), radius: 60))
        let lambda = makeStroke(points: [CGPoint(x: 500, y: 400), CGPoint(x: 530, y: 330),
                                         CGPoint(x: 560, y: 400)])
        let parts = PartExtractor.parts(from: [head, lambda])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].sourceStrokeID, head.id)
    }

    func testHookShapedLegClosesLikeItsAlmostClosedSister() {
        // On-device: two detached leg strokes beside a body — one nearly
        // closed (inflated), one a hook whose endpoints sit ~60pt apart
        // (stayed flat). Visually both read as legs; the deciding geometry
        // is invisible to the user. A gap that is small relative to the
        // SHAPE'S SIZE (bounding-box diagonal) must close.
        let leg = makeStroke(points: [
            CGPoint(x: 100, y: 100), CGPoint(x: 55, y: 160), CGPoint(x: 50, y: 230),
            CGPoint(x: 80, y: 290), CGPoint(x: 140, y: 310), CGPoint(x: 195, y: 285),
            CGPoint(x: 215, y: 230), CGPoint(x: 210, y: 180), CGPoint(x: 200, y: 140),
        ])
        // gap ≈ 108, arc ≈ 480 → ratio limit 96 rejects, absolute 30
        // rejects; bbox 165×210 → diag ≈ 267, 0.5·diag ≈ 133 → closes.
        XCTAssertEqual(PartExtractor.parts(from: [leg]).count, 1,
                       "a hook-shaped leg must close by shape-relative gap")
    }

    func testSingleEndTouchingLineIsNotAPart() {
        // A tail drawn as one line, only one end on the host: no closed
        // region exists (and its area is ~zero) — stays decoration for now.
        let head = makeStroke(points: circlePoints(center: CGPoint(x: 150, y: 150), radius: 60))
        let tail = makeStroke(points: [CGPoint(x: 150, y: 92), CGPoint(x: 150, y: 60),
                                       CGPoint(x: 150, y: 20)])
        let parts = PartExtractor.parts(from: [head, tail])
        XCTAssertEqual(parts.count, 1)
    }

    // MARK: - Loop cleanup (Task 2)

    func testSmoothingPreservesPointCount() {
        let loop = circlePoints(center: CGPoint(x: 100, y: 100), radius: 50)
        let smoothed = PartExtractor.smoothed(loop, passes: 2)
        XCTAssertEqual(smoothed.count, loop.count)
    }

    func testSmoothingReducesWobble() {
        // Alternating ±6 radial jitter: the 1-2-1 kernel cancels it almost exactly
        let center = CGPoint(x: 100, y: 100)
        let steps = 64
        let noisy = (0..<steps).map { i -> CGPoint in
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let r: CGFloat = 50 + (i % 2 == 0 ? 6 : -6)
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        func maxDeviation(_ pts: [CGPoint]) -> CGFloat {
            pts.map { abs(hypot($0.x - center.x, $0.y - center.y) - 50) }.max()!
        }
        let smoothed = PartExtractor.smoothed(noisy, passes: 2)
        XCTAssertLessThan(maxDeviation(smoothed), maxDeviation(noisy) / 2,
                          "Smoothing should at least halve alternating jitter")
    }

    func testSmoothedPartStillCloses() {
        // A noisy near-closed circle must survive extraction with smoothing on
        let center = CGPoint(x: 100, y: 100)
        let noisy = (0...80).map { i -> CGPoint in
            let angle = 2 * CGFloat.pi * 350 / 360 * CGFloat(i) / 80
            let r: CGFloat = 50 + (i % 2 == 0 ? 4 : -4)
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        XCTAssertEqual(PartExtractor.parts(from: [makeStroke(points: noisy)]).count, 1)
    }

    func testOversizedLoopGetsSimplified() {
        // 800-point circle exceeds contourMaxPoints (500) → Douglas–Peucker kicks in
        let loop = circlePoints(center: CGPoint(x: 300, y: 300), radius: 100, steps: 800)
        let parts = PartExtractor.parts(from: [makeStroke(points: loop)])
        XCTAssertEqual(parts.count, 1)
        XCTAssertLessThan(parts[0].contour.count, 500)
    }
}
