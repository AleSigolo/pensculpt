import simd

/// Bounding Volume Hierarchy for accelerated ray casting against a Mesh.
/// Reduces hit-test cost from O(faces) to ~O(log faces).
struct MeshBVH {
    private var nodes: [Node] = []
    private var faceIndices: [Int] = []
    private let positions: [SIMD3<Float>]
    private let faceData: [SIMD3<UInt32>]
    /// Face centroids, needed by the split step at every level. Computed once
    /// up front and dropped when the build finishes: recomputing them inside
    /// the sort comparator (three position lookups and a vector add, per
    /// comparison) was the single biggest cost in tree construction.
    private var centroids: [SIMD3<Float>] = []

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
        centroids = faceData.map { f in
            (positions[Int(f.x)] + positions[Int(f.y)] + positions[Int(f.z)]) / 3
        }
        // A median-split tree over leaves of maxLeafSize has ~2n/maxLeafSize
        // nodes; the old n/2 estimate under-reserved and forced regrowth.
        nodes.reserveCapacity(2 * (faceData.count / Self.maxLeafSize + 1))
        _ = buildNode(start: 0, end: faceData.count)
        centroids = []
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
            // Unrolled deliberately: `for vi in [f.x, f.y, f.z]` heap-allocates
            // an array per face, at every level of the tree.
            let p0 = positions[Int(f.x)]
            let p1 = positions[Int(f.y)]
            let p2 = positions[Int(f.z)]
            lo = simd_min(lo, simd_min(p0, simd_min(p1, p2)))
            hi = simd_max(hi, simd_max(p0, simd_max(p1, p2)))
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
        partitionAroundMedian(start: start, end: end, mid: mid, axis: axis)

        let leftIdx = buildNode(start: start, end: mid)
        let rightIdx = buildNode(start: mid, end: end)
        nodes[nodeIdx].left = Int32(leftIdx)
        nodes[nodeIdx].right = Int32(rightIdx)

        return nodeIdx
    }

    /// Quickselect (nth_element): rearranges `start..<end` so that everything
    /// below `mid` compares no greater on `axis` than everything above it, and
    /// nothing more. That is exactly what the median split consumes — the two
    /// children only ever ask "which side is this face on", never "what is its
    /// rank". Fully sorting each range instead spent O(n log n) per node
    /// answering an O(n) question, at every level of the tree.
    private mutating func partitionAroundMedian(start: Int, end: Int, mid: Int, axis: Int) {
        var lo = start, hi = end - 1
        while lo < hi {
            let pivot = centroids[faceIndices[(lo + hi) / 2]][axis]
            var i = lo, j = hi
            while i <= j {
                while centroids[faceIndices[i]][axis] < pivot { i += 1 }
                while centroids[faceIndices[j]][axis] > pivot { j -= 1 }
                if i <= j {
                    faceIndices.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            // Recurse only into the side that still contains `mid`.
            if mid <= j { hi = j }
            else if mid >= i { lo = i }
            else { break }
        }
    }

    // MARK: - Query

    /// Cast a ray and return the closest front-face hit (smallest t).
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (t: Float, faceIndex: Int)? {
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
                                                         v0: v0, v1: v1, v2: v2),
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
    // Picking rays start on the viewer side and travel INTO the scene
    // (direction −z at identity). `a < -1e-6` accepts faces whose geometric
    // winding normal points along the ray — for ShapeInflater meshes that is
    // the viewer-facing sheet (winding normal −z, shading normal +z), i.e.
    // the surface the user actually sees. Same cull as SurfaceStroke.castOntoMesh.

    private static func rayTriangleIntersect(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                              v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>) -> Float? {
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let h = cross(direction, edge2)
        let a = dot(edge1, h)
        guard a < -1e-6 else { return nil }
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
