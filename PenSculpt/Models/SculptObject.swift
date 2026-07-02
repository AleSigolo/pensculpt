import Foundation
import simd

struct SurfaceStroke: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var points: [SIMD3<Float>]
    var widths: [Float]
    var opacity: Float
    var color: CodableColor

    init(id: UUID = UUID(), points: [SIMD3<Float>] = [], widths: [Float] = [],
         opacity: Float = 1, color: CodableColor = .black) {
        self.id = id
        self.points = points
        self.widths = widths
        self.opacity = opacity
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        points = try container.decode([SIMD3<Float>].self, forKey: .points)
        widths = try container.decodeIfPresent([Float].self, forKey: .widths)
            ?? Array(repeating: 3.0, count: points.count)
        opacity = try container.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        // Pre-2.5D strokes were rendered hardcoded blue; preserve that look.
        color = try container.decodeIfPresent(CodableColor.self, forKey: .color)
            ?? CodableColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1)
    }
}

extension SurfaceStroke {
    /// Projects this 3D surface stroke back to 2D canvas coordinates.
    /// Reverses ShapeInflater's y-negation and discards z.
    func projectTo2D() -> Stroke {
        let strokePoints = points.enumerated().map { i, p in
            StrokePoint(
                location: CGPoint(x: CGFloat(p.x), y: CGFloat(-p.y)),
                pressure: CGFloat(i < widths.count ? widths[i] / 8 : 0.5),
                tilt: .pi / 2,
                azimuth: 0,
                timestamp: TimeInterval(i) * 0.01
            )
        }
        let color = CodableColor(red: self.color.red, green: self.color.green,
                                 blue: self.color.blue,
                                 alpha: self.color.alpha * CGFloat(opacity))
        return Stroke(points: strokePoints, color: color)
    }

    /// Re-projects stroke points onto a new mesh by casting rays along `rayDir`.
    /// Points that miss the mesh are dropped. Returns nil if no points survive.
    func reprojected(onto mesh: Mesh, rayDir: SIMD3<Float>, offset: Float, maxTJump: Float = 50) -> SurfaceStroke? {
        var newPoints: [SIMD3<Float>] = []
        var newWidths: [Float] = []
        var lastT: Float = 0

        for i in 0..<points.count {
            if let (hit, t) = Self.castOntoMesh(from: points[i], direction: rayDir, mesh: mesh, offset: offset) {
                let isFirst = newPoints.isEmpty
                if isFirst || abs(t - lastT) < maxTJump {
                    newPoints.append(hit)
                    newWidths.append(i < widths.count ? widths[i] : 3)
                    lastT = t
                }
            }
        }

        guard newPoints.count > 1 else { return nil }
        return SurfaceStroke(id: id, points: newPoints, widths: newWidths,
                             opacity: opacity, color: color)
    }

    /// Möller–Trumbore cast accepting only faces whose geometric winding
    /// normal points ALONG the ray (`a < -1e-6`) — the same cull as
    /// `MeshBVH.rayTriangleIntersect`, so a −z ray from the viewer side hits
    /// the viewer-facing sheet of a ShapeInflater mesh (winding normal −z).
    /// The hit point is nudged back against the ray (toward the viewer) by
    /// `offset` so strokes render on top of the surface.
    private static func castOntoMesh(from origin: SIMD3<Float>, direction: SIMD3<Float>,
                                      mesh: Mesh, offset: Float) -> (SIMD3<Float>, Float)? {
        var closestT: Float = Float.infinity
        var hitPoint: SIMD3<Float>?

        for face in mesh.faces {
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
            if t > 1e-6 && abs(t) < abs(closestT) {
                closestT = t
                hitPoint = origin + t * direction - direction * offset
            }
        }
        guard let hp = hitPoint else { return nil }
        return (hp, closestT)
    }
}

struct SculptObject: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var mesh: Mesh
    var sourceStrokeIDs: Set<UUID>
    var surfaceStrokes: [SurfaceStroke]
    /// The 2D bounding rect of the source strokes in canvas coordinates.
    /// Used to map the 3D mesh back to its original position on the drawing canvas.
    var originRect: CGRect
    /// Persisted model rotation from the last edit session (identity = as drawn).
    var orientation: simd_quatf
    /// Persisted uniform model scale from the last edit session.
    var scale: Float

    private enum CodingKeys: String, CodingKey {
        case id, mesh, sourceStrokeIDs, surfaceStrokes, originRect, orientation, scale
    }

    init(id: UUID = UUID(), mesh: Mesh, sourceStrokeIDs: Set<UUID>,
         surfaceStrokes: [SurfaceStroke] = [], originRect: CGRect = .zero,
         orientation: simd_quatf = simd_quatf(vector: SIMD4(0, 0, 0, 1)), scale: Float = 1) {
        self.id = id
        self.mesh = mesh
        self.sourceStrokeIDs = sourceStrokeIDs
        self.surfaceStrokes = surfaceStrokes
        self.originRect = originRect
        self.orientation = orientation
        self.scale = scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mesh = try container.decode(Mesh.self, forKey: .mesh)
        sourceStrokeIDs = try container.decode(Set<UUID>.self, forKey: .sourceStrokeIDs)
        surfaceStrokes = try container.decodeIfPresent([SurfaceStroke].self, forKey: .surfaceStrokes) ?? []
        originRect = try container.decodeIfPresent(CGRect.self, forKey: .originRect) ?? .zero
        let ov = try container.decodeIfPresent(SIMD4<Float>.self, forKey: .orientation)
            ?? SIMD4(0, 0, 0, 1)
        // Guard against corrupt data: a non-finite or near-zero quaternion would
        // collapse or NaN-poison the mesh when rotating, so fall back to identity.
        let length = simd_length(ov)
        orientation = length.isFinite && length > 1e-6
            ? simd_quatf(vector: ov / length)
            : simd_quatf(vector: SIMD4(0, 0, 0, 1))
        scale = try container.decodeIfPresent(Float.self, forKey: .scale) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mesh, forKey: .mesh)
        try container.encode(sourceStrokeIDs, forKey: .sourceStrokeIDs)
        try container.encode(surfaceStrokes, forKey: .surfaceStrokes)
        try container.encode(originRect, forKey: .originRect)
        try container.encode(orientation.vector, forKey: .orientation)
        try container.encode(scale, forKey: .scale)
    }
}
