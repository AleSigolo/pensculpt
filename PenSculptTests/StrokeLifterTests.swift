import XCTest
import simd
@testable import PenSculpt

final class StrokeLifterTests: XCTestCase {

    private let identity = simd_quatf(vector: SIMD4(0, 0, 0, 1))

    /// A flat square 100×100 (canvas coords 0...100) at world z = 5, two
    /// triangles wound so the geometric winding normal (cross(e1, e2)) is −z —
    /// the viewer-facing winding (ShapeInflater front-sheet convention) that
    /// `castOntoMesh`'s `a < -1e-6` cull accepts for a −z ray (see
    /// "Picking-ray conventions" in the plan header).
    private func makeFlatMesh() -> Mesh {
        let vertices = [
            MeshVertex(position: SIMD3(0, 0, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(100, 0, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(100, -100, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(0, -100, 5), normal: SIMD3(0, 0, 1)),
        ]
        let faces = [
            MeshFace(indices: SIMD3(0, 1, 2)),
            MeshFace(indices: SIMD3(0, 2, 3)),
        ]
        return Mesh(vertices: vertices, faces: faces)
    }

    private func makeStroke(_ locations: [CGPoint], pressure: CGFloat = 1) -> Stroke {
        Stroke(points: locations.enumerated().map { i, loc in
            StrokePoint(location: loc, pressure: pressure, tilt: .pi / 2,
                        azimuth: 0, timestamp: Double(i) * 0.01)
        })
    }

    func testLiftProjectsOntoMeshAlongMinusZ() {
        let mesh = makeFlatMesh()
        let stroke = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let lifted = StrokeLifter.lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1)
        XCTAssertEqual(lifted[0].points.count, 2)
        // Canvas (20, 30) → world (20, -30, 5 + offset)
        XCTAssertEqual(lifted[0].points[0].x, 20, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[0].y, -30, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[0].z, 5.5, accuracy: 0.01)
        // pressure 1 → width 8 (inverse of the width/8 bake convention)
        XCTAssertEqual(lifted[0].widths[0], 8, accuracy: 0.01)
        XCTAssertEqual(lifted[0].color, stroke.color)
    }

    func testLiftDropsPointsOffTheMesh() {
        let mesh = makeFlatMesh()
        // Second point misses the 100×100 mesh entirely.
        let stroke = makeStroke([CGPoint(x: 50, y: 50), CGPoint(x: 55, y: 55),
                                 CGPoint(x: 500, y: 500)])
        let lifted = StrokeLifter.lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted.count, 1)
        XCTAssertEqual(lifted[0].points.count, 2)
    }

    func testLiftDropsStrokesWithFewerThanTwoHits() {
        let mesh = makeFlatMesh()
        let stroke = makeStroke([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 600)])
        let lifted = StrokeLifter.lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertTrue(lifted.isEmpty)
    }

    func testBakeAtIdentityRoundTripsLift() {
        let mesh = makeFlatMesh()
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let lifted = StrokeLifter.lift([original], onto: mesh, offset: 0.5)
        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked.count, 1)
        XCTAssertEqual(baked[0].points[0].location.x, 20, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[0].location.y, 30, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[1].location.x, 60, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[1].location.y, 70, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[0].pressure, 1, accuracy: 0.05)
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

    func testBakePreservesColor() {
        let blue = CodableColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1)
        let ss = SurfaceStroke(points: [SIMD3(10, -10, 0), SIMD3(20, -20, 0)],
                               widths: [8, 8], color: blue)
        let baked = StrokeLifter.bake([ss], orientation: identity, scale: 1, pivot: .zero)
        XCTAssertEqual(baked[0].color, blue)
    }
}
