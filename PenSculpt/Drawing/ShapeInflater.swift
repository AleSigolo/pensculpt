import Foundation
import simd

enum ShapeInflater {

    /// Runs the full inference pipeline: strokes → inflated 3D mesh → SculptObject.
    static func sculpt(from strokes: [Stroke], config: SculptConfig = .default) -> SculptObject {
        let mesh = inflate(strokes: strokes, config: config)
        let allPoints = strokes.flatMap { $0.points.map(\.location) }
        let xs = allPoints.map(\.x), ys = allPoints.map(\.y)
        let originRect = CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
        return SculptObject(mesh: mesh, sourceStrokeIDs: Set(strokes.map(\.id)), originRect: originRect)
    }

    /// Inflates 2D contours into a closed 3D mesh by using edge distance as
    /// depth. Closed strokes each become an independently inflated part with
    /// its own maxDist, united by a smooth max in the depth field; when no
    /// stroke closes, the whole drawing falls back to the single Vision
    /// contour (previous behavior).
    static func inflate(strokes: [Stroke], config: SculptConfig = .default) -> Mesh {
        let allPoints = strokes.flatMap { $0.points.map(\.location) }

        let parts = PartExtractor.parts(from: strokes, config: config)
        let contours: [[CGPoint]]
        if parts.isEmpty {
            let contour = ContourExtractor.extract(from: strokes, config: config)
            guard contour.count >= 3 else { return Mesh() }
            contours = [contour]
        } else {
            contours = parts.map(\.contour)
        }

        // Bounding box with padding — over ALL strokes, so decoration ink
        // stays inside the grid and originRect mapping is unchanged.
        let xs = allPoints.map(\.x), ys = allPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return Mesh() }

        // Adaptive grid spacing: cap grid to ~150 cells per axis to prevent freezing
        let shapeSize = max(maxX - minX, maxY - minY)
        let gridSpacing = max(config.gridSpacing, shapeSize / 150)
        let pad = gridSpacing * 2
        let x0 = minX - pad, y0 = minY - pad
        let x1 = maxX + pad, y1 = maxY + pad

        let cols = max(2, Int((x1 - x0) / gridSpacing))
        let rows = max(2, Int((y1 - y0) / gridSpacing))
        let cellCount = rows * cols

        // One distance field per part; each field parallelized per-row.
        // containsAndDistance merges point-in-polygon + nearest-edge in one loop.
        var distanceFields = [[Float]](repeating: [], count: contours.count)
        for (pi, contour) in contours.enumerated() {
            var field = [Float](repeating: 0, count: cellCount)
            field.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: rows) { row in
                    let rowOffset = row * cols
                    for col in 0..<cols {
                        let p = CGPoint(x: x0 + CGFloat(col) * gridSpacing,
                                        y: y0 + CGFloat(row) * gridSpacing)
                        let (inside, dist) = containsAndDistance(p, contour: contour)
                        if inside {
                            buffer[rowOffset + col] = Float(dist)
                        }
                    }
                }
            }
            distanceFields[pi] = field
        }

        // Per-part maxDist: a thin limb keeps a thin profile while a fat
        // torso puffs to its own scale.
        let maxDists = distanceFields.map { $0.max() ?? 0 }
        guard maxDists.contains(where: { $0 > 0 }) else { return Mesh() }

        // Spherical profile per part — depth = sqrt(d * (2*maxDist - d)) —
        // then unite parts with a smooth max so overlaps blend at joints.
        let blend = Float(config.partBlendRadius)
        var depths = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let cell = row * cols + col
                var combined: Float = 0
                var hasDepth = false
                for pi in 0..<distanceFields.count {
                    let d = distanceFields[pi][cell]
                    guard d > 0 else { continue }
                    let depth = sqrt(d * (2 * maxDists[pi] - d))
                    combined = hasDepth ? smoothMax(combined, depth, k: blend) : depth
                    hasDepth = true
                }
                depths[row][col] = combined
            }
        }

        // Build mesh: front face (z > 0) + back face (z < 0)
        var boundaryVertices = Set<UInt32>()
        let mesh = buildMesh(depths: depths, rows: rows, cols: cols,
                              x0: Float(x0), y0: Float(y0), spacing: Float(gridSpacing),
                              boundaryVertices: &boundaryVertices)
        return subdivideElongatedEdges(mesh, maxEdgeLength: Float(gridSpacing) * 4,
                                        boundaryVertices: boundaryVertices,
                                        passes: config.seamSubdivisionPasses)
    }

    /// Polynomial smooth maximum (the mirrored SDF smooth-min). k = 0 → hard max.
    private static func smoothMax(_ a: Float, _ b: Float, k: Float) -> Float {
        guard k > 0 else { return max(a, b) }
        let h = max(0, min(1, 0.5 + 0.5 * (b - a) / k))
        return a + (b - a) * h + k * h * (1 - h)
    }

    // MARK: - Combined containment + distance (single pass over contour edges)

    /// Performs point-in-polygon test and nearest-edge distance in one loop.
    private static func containsAndDistance(_ point: CGPoint, contour: [CGPoint]) -> (inside: Bool, distance: CGFloat) {
        var inside = false
        var minDist = CGFloat.infinity
        var j = contour.count - 1
        for i in 0..<contour.count {
            let pi = contour[i]
            let pj = contour[j]

            // Ray-casting containment test
            if (pi.y > point.y) != (pj.y > point.y),
               point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }

            // Distance to segment (pi, pj)
            let dx = pj.x - pi.x, dy = pj.y - pi.y
            let lenSq = dx * dx + dy * dy
            if lenSq <= 0 {
                minDist = min(minDist, hypot(point.x - pi.x, point.y - pi.y))
            } else {
                let t = max(0, min(1, ((point.x - pi.x) * dx + (point.y - pi.y) * dy) / lenSq))
                let projX = pi.x + t * dx, projY = pi.y + t * dy
                minDist = min(minDist, hypot(point.x - projX, point.y - projY))
            }

            j = i
        }
        return (inside, minDist)
    }

    // MARK: - Mesh generation

    private static func buildMesh(depths: [[Float]], rows: Int, cols: Int,
                                   x0: Float, y0: Float, spacing: Float,
                                   boundaryVertices: inout Set<UInt32>) -> Mesh {
        var vertices: [MeshVertex] = []
        var faces: [MeshFace] = []

        // Vertex index map: [row][col] → vertex index for front/back face
        var frontIdx = [[Int]](repeating: [Int](repeating: -1, count: cols), count: rows)
        var backIdx = [[Int]](repeating: [Int](repeating: -1, count: cols), count: rows)

        // Create vertices. Boundary points get a single shared vertex at z=0.
        // Interior points get separate front (z>0) and back (z<0) vertices.
        for row in 0..<rows {
            for col in 0..<cols {
                let d = depths[row][col]
                if d > 0 {
                    let x = x0 + Float(col) * spacing
                    let y = -(y0 + Float(row) * spacing)
                    let boundary = isBoundary(row: row, col: col, depths: depths, rows: rows, cols: cols)

                    if boundary {
                        let idx = vertices.count
                        vertices.append(MeshVertex(position: SIMD3(x, y, 0), normal: SIMD3(0, 0, 1)))
                        frontIdx[row][col] = idx
                        backIdx[row][col] = idx
                        boundaryVertices.insert(UInt32(idx))
                    } else {
                        let normal = computeNormal(depths: depths, row: row, col: col, spacing: spacing, front: true)
                        frontIdx[row][col] = vertices.count
                        vertices.append(MeshVertex(position: SIMD3(x, y, d), normal: normal))
                        backIdx[row][col] = vertices.count
                        vertices.append(MeshVertex(position: SIMD3(x, y, -d), normal: SIMD3(-normal.x, -normal.y, -normal.z)))
                    }
                }
            }
        }

        // Create front and back faces (triangulated grid)
        for row in 0..<(rows - 1) {
            for col in 0..<(cols - 1) {
                let tl = frontIdx[row][col]
                let tr = frontIdx[row][col + 1]
                let bl = frontIdx[row + 1][col]
                let br = frontIdx[row + 1][col + 1]

                // Front face (winding reversed to compensate for Y negation)
                if tl >= 0 && tr >= 0 && bl >= 0 {
                    faces.append(MeshFace(indices: SIMD3(UInt32(tl), UInt32(tr), UInt32(bl))))
                }
                if tr >= 0 && bl >= 0 && br >= 0 {
                    faces.append(MeshFace(indices: SIMD3(UInt32(tr), UInt32(br), UInt32(bl))))
                }

                // Back face
                let tlB = backIdx[row][col]
                let trB = backIdx[row][col + 1]
                let blB = backIdx[row + 1][col]
                let brB = backIdx[row + 1][col + 1]

                if tlB >= 0 && trB >= 0 && blB >= 0 {
                    faces.append(MeshFace(indices: SIMD3(UInt32(tlB), UInt32(blB), UInt32(trB))))
                }
                if trB >= 0 && blB >= 0 && brB >= 0 {
                    faces.append(MeshFace(indices: SIMD3(UInt32(trB), UInt32(blB), UInt32(brB))))
                }
            }
        }

        return Mesh(vertices: vertices, faces: faces)
    }

    // MARK: - Adaptive edge splitting

    private static func subdivideElongatedEdges(_ mesh: Mesh, maxEdgeLength: Float,
                                                 boundaryVertices: Set<UInt32>,
                                                 passes: Int) -> Mesh {
        var vertices = mesh.vertices
        let maxLenSq = maxEdgeLength * maxEdgeLength

        // Separate boundary faces from interior — only boundary faces need splitting
        var seamFaces: [MeshFace] = []
        var interiorFaces: [MeshFace] = []
        for face in mesh.faces {
            let i = face.indices
            if boundaryVertices.contains(i.x) || boundaryVertices.contains(i.y) || boundaryVertices.contains(i.z) {
                seamFaces.append(face)
            } else {
                interiorFaces.append(face)
            }
        }

        for _ in 0..<passes {
            var newFaces: [MeshFace] = []
            newFaces.reserveCapacity(seamFaces.count * 2)
            var edgeMidpoints: [UInt64: UInt32] = [:]
            var changed = false

            for face in seamFaces {
                let i0 = face.indices.x, i1 = face.indices.y, i2 = face.indices.z
                let p0 = vertices[Int(i0)].position
                let p1 = vertices[Int(i1)].position
                let p2 = vertices[Int(i2)].position

                let lenSq01 = simd_length_squared(p1 - p0)
                let lenSq12 = simd_length_squared(p2 - p1)
                let lenSq20 = simd_length_squared(p0 - p2)

                if max(lenSq01, max(lenSq12, lenSq20)) <= maxLenSq {
                    newFaces.append(face)
                    continue
                }

                changed = true

                let (eA, eB): (UInt32, UInt32)
                if lenSq01 >= lenSq12 && lenSq01 >= lenSq20 {
                    (eA, eB) = (i0, i1)
                } else if lenSq12 >= lenSq01 && lenSq12 >= lenSq20 {
                    (eA, eB) = (i1, i2)
                } else {
                    (eA, eB) = (i2, i0)
                }

                let edgeKey = UInt64(min(eA, eB)) | (UInt64(max(eA, eB)) << 32)
                let mid: UInt32
                if let cached = edgeMidpoints[edgeKey] {
                    mid = cached
                } else {
                    let vA = vertices[Int(eA)], vB = vertices[Int(eB)]
                    let pos = (vA.position + vB.position) / 2
                    let norm = normalize((vA.normal + vB.normal) / 2)
                    mid = UInt32(vertices.count)
                    vertices.append(MeshVertex(position: pos, normal: norm))
                    edgeMidpoints[edgeKey] = mid
                }

                if lenSq01 >= lenSq12 && lenSq01 >= lenSq20 {
                    newFaces.append(MeshFace(indices: SIMD3(i0, mid, i2)))
                    newFaces.append(MeshFace(indices: SIMD3(mid, i1, i2)))
                } else if lenSq12 >= lenSq01 && lenSq12 >= lenSq20 {
                    newFaces.append(MeshFace(indices: SIMD3(i0, i1, mid)))
                    newFaces.append(MeshFace(indices: SIMD3(i0, mid, i2)))
                } else {
                    newFaces.append(MeshFace(indices: SIMD3(i0, i1, mid)))
                    newFaces.append(MeshFace(indices: SIMD3(mid, i1, i2)))
                }
            }

            seamFaces = newFaces
            if !changed { break }
        }

        return Mesh(vertices: vertices, faces: interiorFaces + seamFaces)
    }

    private static func isBoundary(row: Int, col: Int, depths: [[Float]],
                                    rows: Int, cols: Int) -> Bool {
        let neighbors = [(row - 1, col), (row + 1, col), (row, col - 1), (row, col + 1)]
        for (nr, nc) in neighbors {
            if nr < 0 || nr >= rows || nc < 0 || nc >= cols || depths[nr][nc] <= 0 {
                return true
            }
        }
        return false
    }

    private static func computeNormal(depths: [[Float]], row: Int, col: Int,
                                       spacing: Float, front: Bool) -> SIMD3<Float> {
        let rows = depths.count, cols = depths[0].count

        let left = col > 0 ? depths[row][col - 1] : 0
        let right = col < cols - 1 ? depths[row][col + 1] : 0
        let up = row > 0 ? depths[row - 1][col] : 0
        let down = row < rows - 1 ? depths[row + 1][col] : 0

        let dx = (right - left) / (2 * spacing)
        let dy = (down - up) / (2 * spacing)

        var normal = normalize(SIMD3<Float>(-dx, -dy, 1))
        if !front { normal.z = -normal.z }
        return normal
    }
}
