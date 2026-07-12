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
