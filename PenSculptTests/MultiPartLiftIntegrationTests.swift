import XCTest
import simd
@testable import PenSculpt

/// End-to-end reproduction of the on-device 5-circles report: separated
/// circles selected together become ONE multi-part object, and every
/// circle's rim ink must ride its own inflated part — no circle may stay
/// behind as flat ghost ink while its volume rotates.
final class MultiPartLiftIntegrationTests: XCTestCase {

    /// A hand-drawn-ish circle: slightly irregular radius, dense sampling
    /// (mimics StrokeConverter's 2pt resampling), small closure gap.
    private func circleStroke(center: CGPoint, radius: CGFloat,
                              wobblePhase: CGFloat = 0) -> Stroke {
        let samples = max(24, Int((2 * .pi * radius) / 2))
        let points = (0..<samples).map { i -> StrokePoint in
            let a = CGFloat(i) / CGFloat(samples) * 2 * .pi * 0.98  // ~7° gap
            let wobble = 1 + 0.04 * sin(a * 5 + wobblePhase)
            return StrokePoint(
                location: CGPoint(x: center.x + radius * wobble * cos(a),
                                  y: center.y + radius * wobble * sin(a)),
                pressure: 1, tilt: .pi / 2, azimuth: 0,
                timestamp: TimeInterval(i) * 0.01)
        }
        return Stroke(points: points)
    }

    func testFiveSeparatedCirclesAllLiftTheirInk() {
        let centers = [CGPoint(x: 200, y: 200), CGPoint(x: 500, y: 180),
                       CGPoint(x: 800, y: 240), CGPoint(x: 320, y: 520),
                       CGPoint(x: 650, y: 560)]
        let strokes = centers.enumerated().map { i, c in
            circleStroke(center: c, radius: 70 + CGFloat(i) * 8,
                         wobblePhase: CGFloat(i))
        }

        let obj = ShapeInflater.sculpt(from: strokes, config: .default)
        XCTAssertFalse(obj.mesh.isEmpty, "five closed circles must inflate")

        let bvh = MeshBVH(mesh: obj.mesh)
        let lift = StrokeLifter.lift(strokes, bvh: bvh,
                                     offset: SculptConfig.default.surfaceStrokeOffset)

        XCTAssertTrue(lift.unliftedStrokeIDs.isEmpty,
                      "every circle's rim ink must ride its part — " +
                      "\(lift.unliftedStrokeIDs.count) of 5 stayed flat ghost ink")

        // Fragmentation guard: a rim should lift as few segments, not shred.
        XCTAssertLessThanOrEqual(lift.lifted.count, strokes.count * 4,
                                 "rim ink shredded into \(lift.lifted.count) segments")

        // Ink-conservation guard: overall point survival must be near-total.
        let totalIn = strokes.reduce(0) { $0 + $1.points.count }
        let totalOut = lift.lifted.reduce(0) { $0 + $1.points.count }
        XCTAssertGreaterThanOrEqual(Float(totalOut) / Float(totalIn), 0.95,
                                    "only \(totalOut)/\(totalIn) ink points survived")
    }
}
