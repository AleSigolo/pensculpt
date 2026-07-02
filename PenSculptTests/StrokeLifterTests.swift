import XCTest
import simd
@testable import PenSculpt

final class StrokeLifterTests: XCTestCase {

    private let identity = simd_quatf(vector: SIMD4(0, 0, 0, 1))

    /// A flat quad spanning canvas x in `xRange`, y in 0...100, at world z = 5,
    /// two triangles wound so the geometric winding normal (cross(e1, e2)) is
    /// −z — the viewer-facing winding (ShapeInflater front-sheet convention)
    /// that the `a < -1e-6` cull accepts for a −z ray (see "Picking-ray
    /// conventions" in the plan header).
    private func quad(xRange: ClosedRange<Float>, baseIndex: UInt32 = 0)
        -> (vertices: [MeshVertex], faces: [MeshFace]) {
        let lo = xRange.lowerBound, hi = xRange.upperBound
        let vertices = [
            MeshVertex(position: SIMD3(lo, 0, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(hi, 0, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(hi, -100, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(lo, -100, 5), normal: SIMD3(0, 0, 1)),
        ]
        let faces = [
            MeshFace(indices: SIMD3(baseIndex, baseIndex + 1, baseIndex + 2)),
            MeshFace(indices: SIMD3(baseIndex, baseIndex + 2, baseIndex + 3)),
        ]
        return (vertices, faces)
    }

    /// A flat square 100×100 (canvas coords 0...100) at world z = 5.
    private func makeFlatMesh() -> Mesh {
        let q = quad(xRange: 0...100)
        return Mesh(vertices: q.vertices, faces: q.faces)
    }

    /// Two quads (x 0...40 and x 60...100) with a gap between them.
    private func makeGappedMesh() -> Mesh {
        let left = quad(xRange: 0...40)
        let right = quad(xRange: 60...100, baseIndex: 4)
        return Mesh(vertices: left.vertices + right.vertices,
                    faces: left.faces + right.faces)
    }

    private func makeStroke(_ locations: [CGPoint], pressure: CGFloat = 1,
                            color: CodableColor = .black) -> Stroke {
        Stroke(points: locations.enumerated().map { i, loc in
            StrokePoint(location: loc, pressure: pressure, tilt: .pi / 2,
                        azimuth: 0, timestamp: Double(i) * 0.01)
        }, color: color)
    }

    private func lift(_ strokes: [Stroke], onto mesh: Mesh, offset: Float,
                      maxTJump: Float = 50)
        -> (lifted: [SurfaceStroke], unliftedStrokeIDs: Set<UUID>) {
        StrokeLifter.lift(strokes, onto: mesh, bvh: MeshBVH(mesh: mesh),
                          offset: offset, maxTJump: maxTJump)
    }

    // MARK: - Lift

    func testLiftProjectsOntoMeshAlongMinusZ() {
        let mesh = makeFlatMesh()
        let stroke = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1)
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points.count, 2)
        // Canvas (20, 30) → world (20, -30, 5 + offset)
        XCTAssertEqual(lifted[0].points[0].x, 20, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[0].y, -30, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[0].z, 5.5, accuracy: 0.01)
        // pressure 1 → width 8 (inverse of the width/8 bake convention)
        XCTAssertEqual(lifted[0].widths[0], 8, accuracy: 0.01)
        XCTAssertEqual(lifted[0].color, stroke.color)
        // Color already carries alpha; session opacity starts neutral.
        XCTAssertEqual(lifted[0].opacity, 1, accuracy: 1e-6)
    }

    func testLiftDropsPointsOffTheMesh() {
        let mesh = makeFlatMesh()
        // Third point misses the 100×100 mesh entirely.
        let stroke = makeStroke([CGPoint(x: 50, y: 50), CGPoint(x: 55, y: 55),
                                 CGPoint(x: 500, y: 500)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted.count, 1)
        XCTAssertEqual(lifted[0].points.count, 2)
        XCTAssertTrue(unlifted.isEmpty)
    }

    func testLiftSplitsIntoSegmentsAcrossAGap() {
        let mesh = makeGappedMesh()
        // Two points on the left quad, one in the gap, two on the right quad.
        let stroke = makeStroke([CGPoint(x: 10, y: 50), CGPoint(x: 20, y: 50),
                                 CGPoint(x: 50, y: 50),
                                 CGPoint(x: 70, y: 50), CGPoint(x: 80, y: 50)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 2)
        XCTAssertTrue(unlifted.isEmpty)
        // No bridging chord: each segment holds only its own quad's points.
        XCTAssertEqual(lifted[0].points.count, 2)
        XCTAssertEqual(lifted[0].points[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[1].x, 20, accuracy: 0.01)
        XCTAssertEqual(lifted[1].points.count, 2)
        XCTAssertEqual(lifted[1].points[0].x, 70, accuracy: 0.01)
        XCTAssertEqual(lifted[1].points[1].x, 80, accuracy: 0.01)
    }

    func testLiftReportsFullyMissingStrokeAsUnlifted() {
        let mesh = makeFlatMesh()
        let stroke = makeStroke([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 600)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertTrue(lifted.isEmpty)
        XCTAssertEqual(unlifted, [stroke.id])
    }

    func testLiftMultipleStrokesPreservesOrder() {
        let mesh = makeFlatMesh()
        let first = makeStroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10)])
        let second = makeStroke([CGPoint(x: 70, y: 90), CGPoint(x: 80, y: 90)])
        let (lifted, unlifted) = lift([first, second], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 2)
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(lifted[1].points[0].x, 70, accuracy: 0.01)
    }

    // MARK: - Bake

    func testBakeAtIdentityRoundTripsLift() {
        let mesh = makeFlatMesh()
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let (lifted, _) = lift([original], onto: mesh, offset: 0.5)
        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked.count, 1)
        XCTAssertEqual(baked[0].points[0].location.x, 20, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[0].location.y, 30, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[1].location.x, 60, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[1].location.y, 70, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[0].pressure, 1, accuracy: 0.05)
    }

    func testRoundTripPreservesHalfPressure() {
        let mesh = makeFlatMesh()
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)],
                                  pressure: 0.5)
        let (lifted, _) = lift([original], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted[0].widths[0], 4, accuracy: 0.01)
        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked[0].points[0].pressure, 0.5, accuracy: 0.001)
    }

    func testTranslucentRoundTripFoldsOpacityIntoAlpha() {
        let mesh = makeFlatMesh()
        let translucent = CodableColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)],
                                  color: translucent)
        let (lifted, _) = lift([original], onto: mesh, offset: 0.5)
        // Lift must not double-count alpha into opacity.
        XCTAssertEqual(lifted[0].opacity, 1, accuracy: 1e-6)
        XCTAssertEqual(lifted[0].color.alpha, 0.5, accuracy: 1e-6)

        // A session that halved the stroke's opacity bakes to alpha 0.25.
        var faded = lifted[0]
        faded.opacity = 0.5
        let baked = StrokeLifter.bake([faded], orientation: identity, scale: 1,
                                      pivot: .zero)
        XCTAssertEqual(baked[0].color.alpha, 0.25, accuracy: 1e-6)
    }

    func testBakeHalfTurnAboutYMirrorsXAboutPivot() {
        let ss = SurfaceStroke(points: [SIMD3(60, -50, 0)], widths: [8], color: .black)
        // Single-point strokes are legal input for bake (min length is enforced at lift).
        let baked = StrokeLifter.bake([ss],
                                      orientation: simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)),
                                      scale: 1, pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked[0].points[0].location.x, 40, accuracy: 0.01)
        XCTAssertEqual(baked[0].points[0].location.y, 50, accuracy: 0.01)
    }

    func testBakeAtScaleTwoDoublesPositionAndPressure() {
        // On screen the strip is scaled by the model matrix, so WYSIWYG bake
        // must scale both position about the pivot and rendered width.
        let ss = SurfaceStroke(points: [SIMD3(60, -50, 0)], widths: [8], color: .black)
        let baked = StrokeLifter.bake([ss], orientation: identity, scale: 2,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked[0].points[0].location.x, 70, accuracy: 0.01)
        XCTAssertEqual(baked[0].points[0].location.y, 50, accuracy: 0.01)
        XCTAssertEqual(baked[0].points[0].pressure, 2, accuracy: 0.001)
    }

    func testBakePreservesColor() {
        let blue = CodableColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1)
        let ss = SurfaceStroke(points: [SIMD3(10, -10, 0), SIMD3(20, -20, 0)],
                               widths: [8, 8], color: blue)
        let baked = StrokeLifter.bake([ss], orientation: identity, scale: 1, pivot: .zero)
        XCTAssertEqual(baked[0].color, blue)
    }
}
