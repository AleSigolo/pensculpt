import XCTest
import simd
import Metal
@testable import PenSculpt

final class SculptRendererTests: XCTestCase {

    private func makeMesh(z: Float) -> Mesh {
        let vertices = [
            MeshVertex(position: SIMD3(0, 0, z), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(100, 0, z), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(100, -100, z), normal: SIMD3(0, 0, 1)),
        ]
        return Mesh(vertices: vertices, faces: [MeshFace(indices: SIMD3(0, 1, 2))])
    }

    private func waitForBuffers(_ renderer: SculptRenderer, _ id: UUID,
                                timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if renderer.hasMeshBuffers(for: id) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return renderer.hasMeshBuffers(for: id)
    }

    /// replaceMesh invalidates the object's GPU buffers; it must also get
    /// them rebuilt. Clearing AFTER the sculptObjects mutation let the didSet
    /// prebuild pass see the stale buffer as present and skip — the mesh
    /// then rendered invisible until the next unrelated renderer sync
    /// (manual check 10: fill vanished for ~5s after dismissing the expand
    /// workspace).
    func testReplaceMeshRebuildsBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable in this environment")
        }
        let renderer = try XCTUnwrap(SculptRenderer(device: device))
        let obj = SculptObject(mesh: makeMesh(z: 5), sourceStrokeIDs: [])
        renderer.sculptObjects = [obj]
        XCTAssertTrue(waitForBuffers(renderer, obj.id, timeout: 3),
                      "initial prebuild must produce buffers")

        renderer.replaceMesh(objectID: obj.id, mesh: makeMesh(z: 9))
        XCTAssertTrue(waitForBuffers(renderer, obj.id, timeout: 3),
                      "replaceMesh must schedule a rebuild of the buffers it invalidates")
    }

    /// Deform runs on every input event of the gesture; clearing the vertex
    /// buffer and waiting for the async prebuild made the mesh invisible for
    /// the whole gesture (manual check 11: "mesh disappears when deforming,
    /// only the 2D strokes remain"). The buffer must be refreshed in place.
    func testDeformKeepsMeshBuffersAlive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable in this environment")
        }
        let renderer = try XCTUnwrap(SculptRenderer(device: device))
        let obj = SculptObject(mesh: makeMesh(z: 5), sourceStrokeIDs: [])
        let originalVertices = obj.mesh.vertices
        renderer.sculptObjects = [obj]
        renderer.activeObjectID = obj.id
        renderer.editPivot = SIMD3(50, -50, 0)
        // Edit sessions start at the identity orientation (the renderer's
        // default rotation is the legacy workspace camera tilt).
        renderer.rotation = simd_quatf(vector: SIMD4(0, 0, 0, 1))
        renderer.cacheBVH(MeshBVH(mesh: obj.mesh), for: obj.id)
        XCTAssertTrue(waitForBuffers(renderer, obj.id, timeout: 3))

        renderer.deformMesh(at: CGPoint(x: 60, y: 40),
                            viewSize: CGSize(width: 1024, height: 1366),
                            strength: 5, radius: 100,
                            screenVelocity: CGPoint(x: 0, y: 30))

        XCTAssertNotEqual(renderer.sculptObjects[0].mesh.vertices.map(\.position),
                          originalVertices.map(\.position),
                          "fixture problem: the deform ray must actually hit the mesh")
        XCTAssertTrue(renderer.hasMeshBuffers(for: obj.id),
                      "deform must refresh the vertex buffer in place, not orphan it")
    }

    func testOrthographicProjectionMapsCorners() {
        let mvp = SculptRenderer.orthographicProjection(
            left: -100, right: 100,
            bottom: -100, top: 100,
            near: -100, far: 100
        )

        // Origin maps to clip-space origin
        let origin = mvp * SIMD4<Float>(0, 0, 0, 1)
        XCTAssertEqual(origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 0, accuracy: 0.001)

        // Left-bottom-near corner maps to (-1, -1, -1)
        let lbn = mvp * SIMD4<Float>(-100, -100, -100, 1)
        XCTAssertEqual(lbn.x, -1, accuracy: 0.001)
        XCTAssertEqual(lbn.y, -1, accuracy: 0.001)

        // Right-top-far corner maps to (1, 1, 1)
        let rtf = mvp * SIMD4<Float>(100, 100, 100, 1)
        XCTAssertEqual(rtf.x, 1, accuracy: 0.001)
        XCTAssertEqual(rtf.y, 1, accuracy: 0.001)
    }

    func testOrthographicProjectionPreservesAspect() {
        let wide = SculptRenderer.orthographicProjection(
            left: -200, right: 200,
            bottom: -100, top: 100,
            near: -1, far: 1
        )

        // A point at (100, 50) should map to (0.5, 0.5) — same relative position
        let p = wide * SIMD4<Float>(100, 50, 0, 1)
        XCTAssertEqual(p.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.001)
    }

    func testOrthographicProjectionIsConsistent() {
        let mvp1 = SculptRenderer.orthographicProjection(
            left: -50, right: 50, bottom: -50, top: 50, near: -10, far: 10
        )
        let mvp2 = SculptRenderer.orthographicProjection(
            left: -50, right: 50, bottom: -50, top: 50, near: -10, far: 10
        )

        let testPoint = SIMD4<Float>(25, 25, 5, 1)
        let p1 = mvp1 * testPoint
        let p2 = mvp2 * testPoint
        XCTAssertEqual(p1.x, p2.x, accuracy: 0.001)
        XCTAssertEqual(p1.y, p2.y, accuracy: 0.001)
        XCTAssertEqual(p1.z, p2.z, accuracy: 0.001)
    }
}
