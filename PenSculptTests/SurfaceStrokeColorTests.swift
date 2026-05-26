import XCTest
import simd
@testable import PenSculpt

final class SurfaceStrokeColorTests: XCTestCase {

    func testCodableRoundTripPreservesColor() throws {
        let red = CodableColor(red: 1, green: 0, blue: 0, alpha: 1)
        let stroke = SurfaceStroke(
            points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)],
            widths: [3, 3],
            opacity: 0.8,
            color: red
        )
        let data = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(SurfaceStroke.self, from: data)
        XCTAssertEqual(decoded.color, red)
    }

    func testLegacyDecodeFallsBackToHistoricBlue() throws {
        // JSON without `color` field — represents docs saved before this feature.
        // SIMD3<Float> serializes as a flat [x, y, z] array.
        let legacyJSON = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "points": [[0, 0, 0], [1, 1, 1]],
            "widths": [3, 3],
            "opacity": 1
        }
        """.data(using: .utf8)!

        let historicBlue = CodableColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1)
        let decoded = try JSONDecoder().decode(SurfaceStroke.self, from: legacyJSON)
        XCTAssertEqual(decoded.color, historicBlue)
    }

    func testSimd4HelperConvertsAndAppliesOpacity() {
        let color = CodableColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.8)
        let v = color.simd4(opacity: 0.5)
        XCTAssertEqual(v.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(v.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(v.z, 0.75, accuracy: 0.001)
        XCTAssertEqual(v.w, 0.4, accuracy: 0.001)  // 0.8 * 0.5
    }

    func testSimd4HelperDefaultOpacityIsIdentity() {
        let color = CodableColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let v = color.simd4()
        XCTAssertEqual(v.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(v.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(v.z, 0.3, accuracy: 0.001)
        XCTAssertEqual(v.w, 1.0, accuracy: 0.001)
    }

    func testProjectTo2DUsesStrokeColor() {
        let green = CodableColor(red: 0, green: 1, blue: 0, alpha: 1)
        let stroke = SurfaceStroke(
            points: [SIMD3<Float>(10, 20, 0), SIMD3<Float>(30, 40, 0)],
            widths: [3, 3],
            opacity: 1,
            color: green
        )
        let projected = stroke.projectTo2D()
        XCTAssertEqual(projected.color.red, 0, accuracy: 0.001)
        XCTAssertEqual(projected.color.green, 1, accuracy: 0.001)
        XCTAssertEqual(projected.color.blue, 0, accuracy: 0.001)
    }

    func testProjectTo2DAppliesOpacityToAlpha() {
        let translucentRed = CodableColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let stroke = SurfaceStroke(
            points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 0)],
            widths: [3, 3],
            opacity: 0.5,
            color: translucentRed
        )
        let projected = stroke.projectTo2D()
        XCTAssertEqual(projected.color.alpha, 0.25, accuracy: 0.001)  // 0.5 * 0.5
    }

    func testReprojectedPreservesColorAndOpacity() throws {
        // Build a tiny mesh (a single triangle on the z=0 plane large enough to catch all points).
        let v0 = MeshVertex(position: SIMD3<Float>(-100, -100, 0), normal: SIMD3<Float>(0, 0, 1))
        let v1 = MeshVertex(position: SIMD3<Float>( 100, -100, 0), normal: SIMD3<Float>(0, 0, 1))
        let v2 = MeshVertex(position: SIMD3<Float>(   0,  100, 0), normal: SIMD3<Float>(0, 0, 1))
        let face = MeshFace(indices: SIMD3<UInt32>(0, 1, 2))
        let mesh = Mesh(vertices: [v0, v1, v2], faces: [face])

        let purple = CodableColor(red: 0.5, green: 0, blue: 0.5, alpha: 1)
        let stroke = SurfaceStroke(
            points: [SIMD3<Float>(0, 0, 5), SIMD3<Float>(10, 0, 5)],  // above the plane, z > 0
            widths: [3, 3],
            opacity: 0.7,
            color: purple
        )

        let bvh = MeshBVH(mesh: mesh)
        let reprojected = try XCTUnwrap(stroke.reprojected(
            onto: bvh,
            rayDir: SIMD3<Float>(0, 0, -1),  // cast straight down onto the plane
            offset: 0
        ))
        XCTAssertEqual(reprojected.color, purple)
        XCTAssertEqual(reprojected.opacity, 0.7, accuracy: 0.001)
    }
}
