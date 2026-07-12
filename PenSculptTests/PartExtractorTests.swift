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
}
