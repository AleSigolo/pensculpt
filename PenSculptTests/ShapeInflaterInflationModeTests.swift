import XCTest
@testable import PenSculpt

final class ShapeInflaterInflationModeTests: XCTestCase {

    /// Builds a stroke shaped like a square so tests have a deterministic contour.
    private func makeSquareStroke(size: CGFloat = 100) -> Stroke {
        let pts: [StrokePoint] = [
            StrokePoint(location: CGPoint(x: 0, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: size, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: size, y: size), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: 0, y: size), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: 0, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ]
        return Stroke(points: pts)
    }

    func testInflateDefaultModeIsOrganic() {
        // Calling inflate without specifying mode produces the same mesh as organic.
        let stroke = makeSquareStroke()
        let defaultMesh = ShapeInflater.inflate(strokes: [stroke])
        let organicMesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .organic)
        XCTAssertEqual(defaultMesh.vertices.count, organicMesh.vertices.count)
        XCTAssertEqual(defaultMesh.faces, organicMesh.faces)
    }

    func testOrganicProducesDomedMesh() {
        // Organic profile: depth varies across the interior — vertices near the center
        // are taller than vertices near the edge.
        let stroke = makeSquareStroke()
        let mesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .organic)
        let frontFaceZs = mesh.vertices.map { $0.position.z }.filter { $0 > 0 }
        guard let minZ = frontFaceZs.min(), let maxZ = frontFaceZs.max() else {
            return XCTFail("Expected at least one front-face vertex")
        }
        XCTAssertGreaterThan(maxZ - minZ, 0.5,
                             "organic mode should produce varying depth (dome), not a flat slab")
    }

    func testStraightProducesFlatTopMesh() {
        // Straight profile: the depth conversion assigns maxDist to every interior
        // cell, resulting in a single unique z-value for all non-boundary grid vertices.
        // Organic produces a dome (many distinct z-values). We verify straight has
        // strictly fewer distinct z-values among positive-z vertices than organic.
        let stroke = makeSquareStroke()
        let organicMesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .organic)
        let straightMesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .straight)

        // Count distinct z-values (rounded to 2 decimal places) among positive-z vertices.
        func distinctPositiveZCount(_ mesh: Mesh) -> Int {
            let zs = mesh.vertices.map { $0.position.z }.filter { $0 > 0 }
            let rounded = Set(zs.map { (($0 * 100).rounded() / 100) })
            return rounded.count
        }

        let organicDistinct = distinctPositiveZCount(organicMesh)
        let straightDistinct = distinctPositiveZCount(straightMesh)

        XCTAssertGreaterThan(organicDistinct, straightDistinct,
                             "organic (dome) should have more distinct z-values than straight (flat top)")
    }
}
