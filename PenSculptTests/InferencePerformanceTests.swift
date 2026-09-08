import XCTest
import simd
@testable import PenSculpt

/// Timing harness for the lift pipeline's three stages, on a figure sized and
/// shaped like the ones the app actually chokes on: a multi-part cartoon
/// animal (head, two ears, torso, four limbs) drawn at roughly 400x550pt.
///
/// This is a diagnostic, not an assertion of speed — CI machines and devices
/// differ far too much to pin a wall-clock budget. It prints a per-stage
/// breakdown so an optimization can be aimed at the stage that dominates
/// instead of guessed at. Run it alone:
///
///     xcodebuild test -only-testing:PenSculptTests/InferencePerformanceTests
final class InferencePerformanceTests: XCTestCase {

    // MARK: - Fixture

    private func closedLoop(center: CGPoint, rx: CGFloat, ry: CGFloat,
                            steps: Int = 64, rotation: CGFloat = 0) -> Stroke {
        let points = (0...steps).map { i -> StrokePoint in
            let a = 2 * .pi * CGFloat(i) / CGFloat(steps)
            let x = rx * cos(a), y = ry * sin(a)
            let rx2 = x * cos(rotation) - y * sin(rotation)
            let ry2 = x * sin(rotation) + y * cos(rotation)
            return StrokePoint(location: CGPoint(x: center.x + rx2, y: center.y + ry2),
                               pressure: 1, tilt: 0, azimuth: 0,
                               timestamp: TimeInterval(i) * 0.01)
        }
        return Stroke(points: points)
    }

    /// Head, two ears, torso, two arms, two legs — eight closed parts, the
    /// shape of the drawing that takes seconds on device.
    private var catStrokes: [Stroke] {
        [
            closedLoop(center: CGPoint(x: 500, y: 500), rx: 75, ry: 60),    // head
            closedLoop(center: CGPoint(x: 452, y: 432), rx: 22, ry: 34, steps: 24, rotation: -0.4), // ear L
            closedLoop(center: CGPoint(x: 556, y: 428), rx: 22, ry: 34, steps: 24, rotation: 0.4),  // ear R
            closedLoop(center: CGPoint(x: 500, y: 720), rx: 130, ry: 150),  // torso
            closedLoop(center: CGPoint(x: 368, y: 640), rx: 26, ry: 62, rotation: 0.5),  // arm L
            closedLoop(center: CGPoint(x: 640, y: 622), rx: 26, ry: 62, rotation: -0.5), // arm R
            closedLoop(center: CGPoint(x: 424, y: 872), rx: 28, ry: 60, rotation: 0.2),  // leg L
            closedLoop(center: CGPoint(x: 588, y: 880), rx: 28, ry: 60, rotation: -0.2), // leg R
        ]
    }

    private func time(_ label: String, _ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print(String(format: "⏱  %-22@ %7.1f ms", label as NSString, elapsed * 1000))
        return elapsed
    }

    // MARK: - Breakdown

    func testLiftPipelineStageBreakdown() {
        let strokes = catStrokes
        let config = SculptConfig.default

        var parts: [Part] = []
        let tParts = time("PartExtractor.parts") {
            parts = PartExtractor.parts(from: strokes, config: config)
        }

        var object = SculptObject(mesh: Mesh(), sourceStrokeIDs: [], originRect: .zero)
        let tSculpt = time("ShapeInflater.sculpt") {
            object = ShapeInflater.sculpt(from: strokes, config: config)
        }

        var bvh: MeshBVH?
        let tBVH = time("MeshBVH build") {
            bvh = MeshBVH(mesh: object.mesh)
        }

        var lifted = 0
        let tLift = time("StrokeLifter.lift") {
            let result = StrokeLifter.lift(strokes, bvh: bvh!,
                                           offset: config.surfaceStrokeOffset)
            lifted = result.lifted.count
        }

        let total = tSculpt + tBVH + tLift
        print(String(format: "⏱  %-22@ %7.1f ms  (sculpt %.0f%%, bvh %.0f%%, lift %.0f%%)",
                     "TOTAL (as on device)" as NSString, total * 1000,
                     tSculpt / total * 100, tBVH / total * 100, tLift / total * 100))
        print("   parts: \(parts.count)  (extract \(Int(tParts * 1000))ms, counted inside sculpt too)")
        print("   contour points: \(parts.map(\.contour.count))")
        print("   mesh: \(object.mesh.vertexCount) verts, \(object.mesh.faceCount) faces")
        print("   lifted strokes: \(lifted)/\(strokes.count)")

        XCTAssertEqual(parts.count, 8, "fixture must stay a genuine multi-part figure")
        XCTAssertFalse(object.mesh.isEmpty, "fixture must produce a mesh to time against")
    }
}
