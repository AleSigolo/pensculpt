import XCTest
import simd
@testable import PenSculpt

final class SculptObjectCodableTests: XCTestCase {

    func testDefaults() {
        let obj = SculptObject(mesh: Mesh(), sourceStrokeIDs: [])
        XCTAssertEqual(obj.orientation.vector, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(obj.scale, 1)
    }

    func testOrientationAndScaleRoundTrip() throws {
        var obj = SculptObject(mesh: Mesh(), sourceStrokeIDs: [])
        obj.orientation = simd_quatf(angle: .pi / 3, axis: SIMD3(0, 1, 0))
        obj.scale = 1.5
        let data = try JSONEncoder().encode(obj)
        let decoded = try JSONDecoder().decode(SculptObject.self, from: data)
        XCTAssertEqual(decoded.orientation.vector.x, obj.orientation.vector.x, accuracy: 1e-6)
        XCTAssertEqual(decoded.orientation.vector.y, obj.orientation.vector.y, accuracy: 1e-6)
        XCTAssertEqual(decoded.orientation.vector.z, obj.orientation.vector.z, accuracy: 1e-6)
        XCTAssertEqual(decoded.orientation.vector.w, obj.orientation.vector.w, accuracy: 1e-6)
        XCTAssertEqual(decoded.scale, 1.5)
    }

    func testLegacyJSONWithoutNewFieldsDecodes() throws {
        // Simulates a pre-2.5D document: no orientation, scale, or stroke color.
        let legacy = """
        {"id":"\(UUID().uuidString)","mesh":{"vertices":[],"faces":[]},
         "sourceStrokeIDs":[],"surfaceStrokes":[
           {"id":"\(UUID().uuidString)","points":[[1,2,3],[4,5,6]],"opacity":1}
         ]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SculptObject.self, from: legacy)
        XCTAssertEqual(decoded.orientation.vector, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(decoded.scale, 1)
        // Legacy surface strokes keep their historical blue so old drawings look unchanged.
        XCTAssertEqual(decoded.surfaceStrokes[0].color,
                       CodableColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1))
    }

    func testNewSurfaceStrokeDefaultsToBlack() {
        let stroke = SurfaceStroke(points: [SIMD3(0, 0, 0)], widths: [3])
        XCTAssertEqual(stroke.color, .black)
    }

    func testProjectTo2DUsesStrokeColor() {
        let red = CodableColor(red: 1, green: 0, blue: 0, alpha: 1)
        let stroke = SurfaceStroke(points: [SIMD3(10, -20, 5), SIMD3(30, -40, 5)],
                                   widths: [4, 4], color: red)
        let flat = stroke.projectTo2D()
        XCTAssertEqual(flat.color, red)
        XCTAssertEqual(flat.points[0].location, CGPoint(x: 10, y: 20))
    }

    func testProjectTo2DMultipliesColorAlphaByOpacity() {
        let stroke = SurfaceStroke(points: [SIMD3(10, -20, 5), SIMD3(30, -40, 5)],
                                   widths: [4, 4], opacity: 0.5,
                                   color: CodableColor(red: 1, green: 0, blue: 0, alpha: 0.8))
        let flat = stroke.projectTo2D()
        XCTAssertEqual(flat.color.red, 1)
        XCTAssertEqual(Float(flat.color.alpha), 0.8 * 0.5, accuracy: 1e-6)
    }

    func testReprojectedPreservesColorAndOpacity() throws {
        // One quad at z=0 wound so its geometric normal points +z, which is the
        // side castOntoMesh hits for a ray direction of (0, 0, -1).
        let normal = SIMD3<Float>(0, 0, 1)
        let mesh = Mesh(
            vertices: [
                MeshVertex(position: SIMD3(0, 0, 0), normal: normal),
                MeshVertex(position: SIMD3(100, 0, 0), normal: normal),
                MeshVertex(position: SIMD3(100, -100, 0), normal: normal),
                MeshVertex(position: SIMD3(0, -100, 0), normal: normal),
            ],
            faces: [MeshFace(indices: SIMD3(0, 2, 1)), MeshFace(indices: SIMD3(0, 3, 2))]
        )
        let red = CodableColor(red: 1, green: 0, blue: 0, alpha: 1)
        let stroke = SurfaceStroke(points: [SIMD3(30, -10, 10), SIMD3(60, -20, 10)],
                                   widths: [4, 4], opacity: 0.5, color: red)
        let reprojected = try XCTUnwrap(stroke.reprojected(onto: mesh,
                                                           rayDir: SIMD3(0, 0, -1),
                                                           offset: 0))
        XCTAssertEqual(reprojected.color, red)
        XCTAssertEqual(reprojected.opacity, 0.5)
    }

    func testCorruptZeroOrientationDecodesToIdentity() throws {
        let corrupt = """
        {"id":"\(UUID().uuidString)","mesh":{"vertices":[],"faces":[]},
         "sourceStrokeIDs":[],"surfaceStrokes":[],
         "orientation":[0,0,0,0],"scale":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SculptObject.self, from: corrupt)
        XCTAssertEqual(decoded.orientation.vector, SIMD4<Float>(0, 0, 0, 1))
    }
}
