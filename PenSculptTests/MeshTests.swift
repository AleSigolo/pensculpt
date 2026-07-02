import XCTest
import simd
@testable import PenSculpt

final class MeshTests: XCTestCase {

    func testEmptyMesh() {
        let mesh = Mesh()
        XCTAssertTrue(mesh.isEmpty)
        XCTAssertEqual(mesh.vertexCount, 0)
        XCTAssertEqual(mesh.faceCount, 0)
    }

    func testMeshWithData() {
        let vertices = [
            MeshVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1))
        ]
        let faces = [MeshFace(indices: SIMD3(0, 1, 2))]
        let mesh = Mesh(vertices: vertices, faces: faces)

        XCTAssertFalse(mesh.isEmpty)
        XCTAssertEqual(mesh.vertexCount, 3)
        XCTAssertEqual(mesh.faceCount, 1)
    }

    func testMeshCodable() throws {
        let vertices = [
            MeshVertex(position: SIMD3(1, 2, 3), normal: SIMD3(0, 1, 0)),
            MeshVertex(position: SIMD3(4, 5, 6), normal: SIMD3(0, 1, 0))
        ]
        let faces = [MeshFace(indices: SIMD3(0, 1, 0))]
        let mesh = Mesh(vertices: vertices, faces: faces)

        let data = try JSONEncoder().encode(mesh)
        let decoded = try JSONDecoder().decode(Mesh.self, from: data)

        XCTAssertEqual(decoded.vertexCount, 2)
        XCTAssertEqual(decoded.faceCount, 1)
        XCTAssertEqual(decoded.vertices[0].position, SIMD3(1, 2, 3))
        XCTAssertEqual(decoded.vertices[1].normal, SIMD3(0, 1, 0))
        XCTAssertEqual(decoded.faces[0].indices, SIMD3<UInt32>(0, 1, 0))
    }

    func testMeshEquatable() {
        let v = MeshVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1))
        let f = MeshFace(indices: SIMD3(0, 0, 0))
        let a = Mesh(vertices: [v], faces: [f])
        let b = Mesh(vertices: [v], faces: [f])
        XCTAssertEqual(a, b)
    }

    func testMeshIsEmptyWithVerticesButNoFaces() {
        let v = MeshVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1))
        let mesh = Mesh(vertices: [v], faces: [])
        XCTAssertTrue(mesh.isEmpty)
    }
}

final class MeshBVHTests: XCTestCase {

    /// Brute-force ray cast for comparison. Uses the same `a < -1e-6` cull as
    /// MeshBVH.rayTriangleIntersect: only faces whose geometric winding normal
    /// points ALONG the ray are hit (for a −z picking ray, the viewer-facing
    /// sheet of a ShapeInflater mesh).
    private func bruteForceRaycast(mesh: Mesh, origin: SIMD3<Float>, direction: SIMD3<Float>) -> (t: Float, faceIndex: Int)? {
        var closestT: Float = Float.infinity
        var hitFace = -1
        for (fi, face) in mesh.faces.enumerated() {
            let v0 = mesh.vertices[Int(face.indices.x)].position
            let v1 = mesh.vertices[Int(face.indices.y)].position
            let v2 = mesh.vertices[Int(face.indices.z)].position
            let edge1 = v1 - v0, edge2 = v2 - v0
            let h = cross(direction, edge2)
            let a = dot(edge1, h)
            guard a < -1e-6 else { continue }
            let f = 1.0 / a
            let s = origin - v0
            let u = f * dot(s, h)
            guard u >= 0 && u <= 1 else { continue }
            let q = cross(s, edge1)
            let v = f * dot(direction, q)
            guard v >= 0 && u + v <= 1 else { continue }
            let t = f * dot(edge2, q)
            guard t > 1e-6 else { continue }
            if t < closestT { closestT = t; hitFace = fi }
        }
        return hitFace >= 0 ? (closestT, hitFace) : nil
    }

    /// Two parallel quads at z=5 and z=0, both wound with geometric winding
    /// normal −z (the real ShapeInflater viewer-facing convention). A picking
    /// ray from the viewer side (+z) travelling −z must hit the NEARER quad
    /// (z=5) — `a < -1e-6` accepts exactly these viewer-facing triangles.
    func testBVHReturnsNearestSurface() throws {
        let vertices = [
            MeshVertex(position: SIMD3(-1, -1, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3( 1, -1, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3( 1,  1, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(-1,  1, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(-1, -1, 0), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3( 1, -1, 0), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3( 1,  1, 0), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(-1,  1, 0), normal: SIMD3(0, 0, 1)),
        ]
        let faces = [
            // Winding normal −z → a < -1e-6 for a −z ray → accepted
            MeshFace(indices: SIMD3(0, 2, 1)), MeshFace(indices: SIMD3(0, 3, 2)),
            MeshFace(indices: SIMD3(4, 6, 5)), MeshFace(indices: SIMD3(4, 7, 6)),
        ]
        let mesh = Mesh(vertices: vertices, faces: faces)
        let bvh = MeshBVH(mesh: mesh)

        let origin = SIMD3<Float>(0, 0, 10)
        let direction = SIMD3<Float>(0, 0, -1)

        let bvhResult = try XCTUnwrap(bvh.raycast(origin: origin, direction: direction))
        let bruteResult = try XCTUnwrap(bruteForceRaycast(mesh: mesh, origin: origin, direction: direction))

        XCTAssertEqual(bvhResult.t, bruteResult.t, accuracy: 1e-4)
        // Nearest quad to the viewer at z=10 is z=5 → t=5
        XCTAssertEqual(bvhResult.t, 5.0, accuracy: 1e-4,
                       "Should hit nearest surface at z=5, got t=\(bvhResult.t)")
    }

    /// Many overlapping layers — BVH must still find the closest to the viewer.
    func testBVHWithManyOverlappingLayers() throws {
        var vertices: [MeshVertex] = []
        var faces: [MeshFace] = []
        // Create 10 quads at z = 0..9 wound with winding normal −z
        // (viewer-facing for the conventional −z picking ray)
        for layer in 0..<10 {
            let z = Float(layer)
            let base = UInt32(layer * 4)
            vertices.append(contentsOf: [
                MeshVertex(position: SIMD3(-1, -1, z), normal: SIMD3(0, 0, 1)),
                MeshVertex(position: SIMD3( 1, -1, z), normal: SIMD3(0, 0, 1)),
                MeshVertex(position: SIMD3( 1,  1, z), normal: SIMD3(0, 0, 1)),
                MeshVertex(position: SIMD3(-1,  1, z), normal: SIMD3(0, 0, 1)),
            ])
            faces.append(MeshFace(indices: SIMD3(base, base+2, base+1)))
            faces.append(MeshFace(indices: SIMD3(base, base+3, base+2)))
        }
        let mesh = Mesh(vertices: vertices, faces: faces)
        let bvh = MeshBVH(mesh: mesh)

        let origin = SIMD3<Float>(0, 0, 20)
        let direction = SIMD3<Float>(0, 0, -1)

        let bvhResult = try XCTUnwrap(bvh.raycast(origin: origin, direction: direction))
        let bruteResult = try XCTUnwrap(bruteForceRaycast(mesh: mesh, origin: origin, direction: direction))

        // Nearest layer to the viewer at z=20 is z=9, so t should be 11
        XCTAssertEqual(bvhResult.t, 11.0, accuracy: 1e-4,
                       "Should hit nearest layer at z=9, got t=\(bvhResult.t)")
        XCTAssertEqual(bvhResult.t, bruteResult.t, accuracy: 1e-4)
    }

    /// Reproduce the exact hitTest math using ShapeInflater's actual winding convention.
    /// ShapeInflater front faces (tl, tr, bl)/(tr, br, bl) have GEOMETRIC winding
    /// normal −z (shading normal +z) — that is the viewer-facing sheet, and the
    /// `a < -1e-6` cull accepts it for a picking ray travelling −z.
    /// tl/tr/bl/br refer to CANVAS orientation (world y = −canvas y), exactly
    /// like ShapeInflater.buildMesh and the MetalConventionTests pillow fixture.
    func testHitTestWithShapeInflaterWinding() throws {
        let vertices = [
            // Front (viewer-facing) sheet at z=+5, shading normals +z —
            // large enough to always be hit
            MeshVertex(position: SIMD3(-50,  50, 5), normal: SIMD3(0, 0, 1)),  // 0 tl
            MeshVertex(position: SIMD3( 50,  50, 5), normal: SIMD3(0, 0, 1)),  // 1 tr
            MeshVertex(position: SIMD3(-50, -50, 5), normal: SIMD3(0, 0, 1)),  // 2 bl
            MeshVertex(position: SIMD3( 50, -50, 5), normal: SIMD3(0, 0, 1)),  // 3 br
            // Back sheet at z=-5, shading normals −z
            MeshVertex(position: SIMD3(-50,  50, -5), normal: SIMD3(0, 0, -1)), // 4 tlB
            MeshVertex(position: SIMD3( 50,  50, -5), normal: SIMD3(0, 0, -1)), // 5 trB
            MeshVertex(position: SIMD3(-50, -50, -5), normal: SIMD3(0, 0, -1)), // 6 blB
            MeshVertex(position: SIMD3( 50, -50, -5), normal: SIMD3(0, 0, -1)), // 7 brB
        ]
        let faces = [
            // Front winding: (tl, tr, bl), (tr, br, bl) → geometric winding normal −z
            MeshFace(indices: SIMD3(0, 1, 2)),
            MeshFace(indices: SIMD3(1, 3, 2)),
            // Back winding: (tlB, blB, trB), (trB, blB, brB) → geometric winding normal +z
            MeshFace(indices: SIMD3(4, 6, 5)),
            MeshFace(indices: SIMD3(5, 6, 7)),
        ]
        let mesh = Mesh(vertices: vertices, faces: faces)

        // Set up projection matching SculptRenderer
        var minP = SIMD3<Float>(repeating: Float.infinity)
        var maxP = SIMD3<Float>(repeating: -Float.infinity)
        for v in mesh.vertices { minP = min(minP, v.position); maxP = max(maxP, v.position) }
        let center = (minP + maxP) / 2
        let extent = maxP - minP
        let r = max(extent.x, max(extent.y, extent.z)) / 2 * 1.3
        let viewSize = CGSize(width: 1024, height: 1024)
        let proj = SculptRenderer.orthographicProjection(
            left: -r, right: r, bottom: -r, top: r, near: -r * 10, far: r * 10)
        func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
            simd_float4x4(columns: (
                SIMD4<Float>(1,0,0,0), SIMD4<Float>(0,1,0,0),
                SIMD4<Float>(0,0,1,0), SIMD4<Float>(x,y,z,1)))
        }
        // Use the actual default rotation from SculptRenderer
        let cameraTilt: Float = 0.8
        let rotation = simd_quatf(angle: -cameraTilt, axis: SIMD3(1, 0, 0))
        let view = simd_float4x4(rotation) * translation(-center.x, -center.y, -center.z)
        let mvp = proj * view
        let invMVP = mvp.inverse

        // Unproject NDC z 0 → 1 exactly like SculptRenderer.unprojectRay:
        // origin on the viewer side, ray travelling into the scene.
        let ndcX = Float(2 * 512.0 / viewSize.width - 1)
        let ndcY = Float(1 - 2 * 512.0 / viewSize.height)
        let origin4 = invMVP * SIMD4<Float>(ndcX, ndcY, 0, 1)
        let target4 = invMVP * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let origin = SIMD3<Float>(origin4.x, origin4.y, origin4.z) / origin4.w
        let target = SIMD3<Float>(target4.x, target4.y, target4.z) / target4.w
        let direction = normalize(target - origin)

        let bvh = MeshBVH(mesh: mesh)
        let result = try XCTUnwrap(bvh.raycast(origin: origin, direction: direction),
                                   "Should hit the visible surface")
        let hitPoint = origin + result.t * direction
        // The viewer-facing (visible) surface is at z=+5.
        // With origin on the viewer side, smallest t = nearest to viewer.
        XCTAssertEqual(hitPoint.z, 5.0, accuracy: 0.1,
            "Should hit visible surface at z=+5, got z=\(hitPoint.z)")
    }

    /// Exhaustive comparison: cast many rays and verify BVH matches brute force.
    func testBVHMatchesBruteForceExhaustive() {
        // Build a mesh with front and back surfaces (like ShapeInflater output)
        var vertices: [MeshVertex] = []
        var faces: [MeshFace] = []
        let gridSize = 10
        // Front surface (z > 0, normals +z)
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let fx = Float(x) - Float(gridSize)/2
                let fy = Float(y) - Float(gridSize)/2
                let z = 5.0 - 0.1 * (fx*fx + fy*fy) // dome shape
                vertices.append(MeshVertex(position: SIMD3(fx, fy, Float(z)), normal: SIMD3(0, 0, 1)))
            }
        }
        // Back surface (z < 0, normals -z)
        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let fx = Float(x) - Float(gridSize)/2
                let fy = Float(y) - Float(gridSize)/2
                let z = -(5.0 - 0.1 * (fx*fx + fy*fy))
                vertices.append(MeshVertex(position: SIMD3(fx, fy, Float(z)), normal: SIMD3(0, 0, -1)))
            }
        }
        // Front surface faces (winding normal −z → viewer-facing for a −z ray)
        let n = gridSize
        for y in 0..<(n-1) {
            for x in 0..<(n-1) {
                let i = UInt32(y * n + x)
                faces.append(MeshFace(indices: SIMD3(i, i+UInt32(n)+1, i+1)))
                faces.append(MeshFace(indices: SIMD3(i, i+UInt32(n), i+UInt32(n)+1)))
            }
        }
        // Back surface faces (winding normal +z → culled for a −z ray)
        let offset = UInt32(n * n)
        for y in 0..<(n-1) {
            for x in 0..<(n-1) {
                let i = offset + UInt32(y * n + x)
                faces.append(MeshFace(indices: SIMD3(i, i+1, i+UInt32(n)+1)))
                faces.append(MeshFace(indices: SIMD3(i, i+UInt32(n)+1, i+UInt32(n))))
            }
        }

        let mesh = Mesh(vertices: vertices, faces: faces)
        let bvh = MeshBVH(mesh: mesh)
        let direction = SIMD3<Float>(0, 0, -1)
        var mismatches = 0

        // Cast rays across a grid (from the viewer side at +z, travelling −z)
        for sy in stride(from: -4.0, through: 4.0, by: 0.5) {
            for sx in stride(from: -4.0, through: 4.0, by: 0.5) {
                let origin = SIMD3<Float>(Float(sx), Float(sy), 20)
                let bvhResult = bvh.raycast(origin: origin, direction: direction)
                let bruteResult = bruteForceRaycast(mesh: mesh, origin: origin, direction: direction)

                if let bvhR = bvhResult, let bruteR = bruteResult {
                    if abs(bvhR.t - bruteR.t) > 1e-3 {
                        mismatches += 1
                        XCTFail("Mismatch at (\(sx),\(sy)): BVH t=\(bvhR.t) face=\(bvhR.faceIndex), brute t=\(bruteR.t) face=\(bruteR.faceIndex)")
                    }
                } else if (bvhResult == nil) != (bruteResult == nil) {
                    mismatches += 1
                    XCTFail("Hit/miss mismatch at (\(sx),\(sy)): BVH=\(bvhResult != nil), brute=\(bruteResult != nil)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches) mismatches between BVH and brute force")
    }
}

final class SculptObjectTests: XCTestCase {

    func testSculptObjectInit() {
        let mesh = Mesh(
            vertices: [MeshVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1))],
            faces: [MeshFace(indices: SIMD3(0, 0, 0))]
        )
        let strokeID = UUID()
        let obj = SculptObject(mesh: mesh, sourceStrokeIDs: [strokeID])

        XCTAssertFalse(obj.id.uuidString.isEmpty)
        XCTAssertEqual(obj.mesh.vertexCount, 1)
        XCTAssertTrue(obj.sourceStrokeIDs.contains(strokeID))
    }

    func testSculptObjectCodable() throws {
        let mesh = Mesh(
            vertices: [
                MeshVertex(position: SIMD3(1, 2, 3), normal: SIMD3(0, 1, 0)),
                MeshVertex(position: SIMD3(4, 5, 6), normal: SIMD3(0, 1, 0)),
                MeshVertex(position: SIMD3(7, 8, 9), normal: SIMD3(0, 1, 0))
            ],
            faces: [MeshFace(indices: SIMD3(0, 1, 2))]
        )
        let strokeID = UUID()
        let obj = SculptObject(mesh: mesh, sourceStrokeIDs: [strokeID])

        let data = try JSONEncoder().encode(obj)
        let decoded = try JSONDecoder().decode(SculptObject.self, from: data)

        XCTAssertEqual(decoded.id, obj.id)
        XCTAssertEqual(decoded.mesh, mesh)
        XCTAssertEqual(decoded.sourceStrokeIDs, [strokeID])
    }

    func testSculptObjectEquatable() {
        let id = UUID()
        let mesh = Mesh()
        let strokeIDs: Set<UUID> = [UUID()]
        let a = SculptObject(id: id, mesh: mesh, sourceStrokeIDs: strokeIDs)
        let b = SculptObject(id: id, mesh: mesh, sourceStrokeIDs: strokeIDs)
        XCTAssertEqual(a, b)
    }
}
