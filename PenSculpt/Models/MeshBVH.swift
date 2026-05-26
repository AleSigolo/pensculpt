import simd

/// Bounding Volume Hierarchy for accelerated ray casting against a Mesh.
/// Reduces hit-test cost from O(faces) to ~O(log faces).
struct MeshBVH: Sendable {
    private var nodes: [Node] = []
    private var faceIndices: [Int] = []
    private let positions: [SIMD3<Float>]
    private let faceData: [SIMD3<UInt32>]

    private static let maxLeafSize = 8

    private struct Node {
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var left: Int32
        var right: Int32
        var start: Int32
        var count: Int32
    }

    init(mesh: Mesh) {
        positions = mesh.vertices.map(\.position)
        faceData = mesh.faces.map(\.indices)
        faceIndices = Array(0..<faceData.count)
        guard !faceData.isEmpty else { return }
        nodes.reserveCapacity(faceData.count / 2)
        _ = buildNode(start: 0, end: faceData.count)
    }

    // MARK: - Build

    private mutating func buildNode(start: Int, end: Int) -> Int {
        let nodeIdx = nodes.count
        nodes.append(Node(boundsMin: .zero, boundsMax: .zero,
                          left: -1, right: -1, start: 0, count: 0))

        var lo = SIMD3<Float>(repeating: Float.infinity)
        var hi = SIMD3<Float>(repeating: -Float.infinity)
        for i in start..<end {
            let f = faceData[faceIndices[i]]
            for vi in [f.x, f.y, f.z] {
                let p = positions[Int(vi)]
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
        }
        // Expand bounds by epsilon so triangles on AABB boundaries are not
        // missed when ray direction has zero components (0 * inf = NaN in slab test).
        let eps = SIMD3<Float>(repeating: 1e-4)
        nodes[nodeIdx].boundsMin = lo - eps
        nodes[nodeIdx].boundsMax = hi + eps

        let count = end - start
        if count <= Self.maxLeafSize {
            nodes[nodeIdx].start = Int32(start)
            nodes[nodeIdx].count = Int32(count)
            return nodeIdx
        }

        // Split along longest axis by centroid median
        let extent = hi - lo
        let axis: Int
        if extent.x >= extent.y && extent.x >= extent.z { axis = 0 }
        else if extent.y >= extent.z { axis = 1 }
        else { axis = 2 }

        let mid = (start + end) / 2
        sortRange(start: start, end: end, axis: axis)

        let leftIdx = buildNode(start: start, end: mid)
        let rightIdx = buildNode(start: mid, end: end)
        nodes[nodeIdx].left = Int32(leftIdx)
        nodes[nodeIdx].right = Int32(rightIdx)

        return nodeIdx
    }

    private mutating func sortRange(start: Int, end: Int, axis: Int) {
        let faces = faceData
        let pos = positions
        faceIndices[start..<end].sort { a, b in
            let fa = faces[a], fb = faces[b]
            let ca = (pos[Int(fa.x)] + pos[Int(fa.y)] + pos[Int(fa.z)])[axis]
            let cb = (pos[Int(fb.x)] + pos[Int(fb.y)] + pos[Int(fb.z)])[axis]
            return ca < cb
        }
    }

    // MARK: - Query

    /// Cast a ray and return the closest hit (smallest t).
    /// `doubleSided`: when false (default) only camera-facing triangles are hit
    /// (matches scene-side rays). When true, both faces are hittable — needed
    /// when the ray points in the opposite direction (e.g. reprojection rays
    /// that travel from above the mesh straight down).
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, doubleSided: Bool = false) -> (t: Float, faceIndex: Int)? {
        guard !nodes.isEmpty else { return nil }
        let invDir = SIMD3<Float>(1 / direction.x, 1 / direction.y, 1 / direction.z)

        var closestT: Float = Float.infinity
        var hitFace = -1
        var stack = ContiguousArray<Int32>()
        stack.reserveCapacity(64)
        stack.append(0)

        while let nodeIdx = stack.popLast() {
            let node = nodes[Int(nodeIdx)]

            guard rayIntersectsAABB(origin: origin, invDir: invDir,
                                    lo: node.boundsMin, hi: node.boundsMax,
                                    maxT: closestT) else { continue }

            if node.count > 0 {
                // Leaf
                for i in Int(node.start)..<Int(node.start + node.count) {
                    let fi = faceIndices[i]
                    let f = faceData[fi]
                    let v0 = positions[Int(f.x)]
                    let v1 = positions[Int(f.y)]
                    let v2 = positions[Int(f.z)]
                    if let t = Self.rayTriangleIntersect(origin: origin, direction: direction,
                                                         v0: v0, v1: v1, v2: v2,
                                                         doubleSided: doubleSided),
                       t < closestT {
                        closestT = t
                        hitFace = fi
                    }
                }
            } else {
                if node.left >= 0 { stack.append(node.left) }
                if node.right >= 0 { stack.append(node.right) }
            }
        }

        return hitFace >= 0 ? (closestT, hitFace) : nil
    }

    // MARK: - Ray-AABB (slab method)

    private func rayIntersectsAABB(origin: SIMD3<Float>, invDir: SIMD3<Float>,
                                    lo: SIMD3<Float>, hi: SIMD3<Float>,
                                    maxT: Float) -> Bool {
        let t1 = (lo - origin) * invDir
        let t2 = (hi - origin) * invDir
        let tmin = simd_min(t1, t2)
        let tmax = simd_max(t1, t2)
        let enter = max(tmin.x, max(tmin.y, tmin.z))
        let exit = min(tmax.x, min(tmax.y, tmax.z))
        return enter <= exit && exit > 0 && enter < maxT
    }

    // MARK: - Ray-triangle (Moller-Trumbore, camera-facing)
    // The ray points from the scene side toward the camera, so camera-facing
    // triangles have a < 0 (their normal opposes the ray in the Moller-Trumbore sense).
    // `doubleSided` accepts hits from either side (used by reprojection rays
    // that travel opposite the scene→camera direction).

    private static func rayTriangleIntersect(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                              v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
                                              doubleSided: Bool) -> Float? {
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let h = cross(direction, edge2)
        let a = dot(edge1, h)
        if doubleSided {
            guard abs(a) > 1e-6 else { return nil }
        } else {
            guard a < -1e-6 else { return nil }
        }
        let f = 1.0 / a
        let s = origin - v0
        let u = f * dot(s, h)
        guard u >= 0 && u <= 1 else { return nil }
        let q = cross(s, edge1)
        let v = f * dot(direction, q)
        guard v >= 0 && u + v <= 1 else { return nil }
        let t = f * dot(edge2, q)
        return t > 1e-6 ? t : nil
    }
}
