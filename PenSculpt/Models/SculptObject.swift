import Foundation
import simd

enum InflationMode: String, Codable, Equatable, Sendable {
    case organic
    case straight
}

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
        let projColor = CodableColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha * CGFloat(opacity)
        )
        return Stroke(points: strokePoints, color: projColor)
    }

    /// Re-projects stroke points onto a new mesh by casting rays along `rayDir`.
    /// Points that miss the mesh are dropped. Returns nil if no points survive.
    /// Uses the BVH for O(log n) ray casts instead of brute-force face iteration.
    func reprojected(onto bvh: MeshBVH, rayDir: SIMD3<Float>, offset: Float, maxTJump: Float = 50) -> SurfaceStroke? {
        var newPoints: [SIMD3<Float>] = []
        var newWidths: [Float] = []
        var lastT: Float = 0

        for i in 0..<points.count {
            guard let result = bvh.raycast(origin: points[i], direction: rayDir, doubleSided: true) else { continue }
            let t = result.t
            let isFirst = newPoints.isEmpty
            if isFirst || abs(t - lastT) < maxTJump {
                let hit = points[i] + t * rayDir - rayDir * offset
                newPoints.append(hit)
                newWidths.append(i < widths.count ? widths[i] : 3)
                lastT = t
            }
        }

        guard newPoints.count > 1 else { return nil }
        return SurfaceStroke(id: id, points: newPoints, widths: newWidths,
                             opacity: opacity, color: color)
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
    var inflationMode: InflationMode = .organic

    init(id: UUID = UUID(), mesh: Mesh, sourceStrokeIDs: Set<UUID>,
         surfaceStrokes: [SurfaceStroke] = [], originRect: CGRect = .zero,
         inflationMode: InflationMode = .organic) {
        self.id = id
        self.mesh = mesh
        self.sourceStrokeIDs = sourceStrokeIDs
        self.surfaceStrokes = surfaceStrokes
        self.originRect = originRect
        self.inflationMode = inflationMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mesh = try container.decode(Mesh.self, forKey: .mesh)
        sourceStrokeIDs = try container.decode(Set<UUID>.self, forKey: .sourceStrokeIDs)
        surfaceStrokes = try container.decodeIfPresent([SurfaceStroke].self, forKey: .surfaceStrokes) ?? []
        originRect = try container.decodeIfPresent(CGRect.self, forKey: .originRect) ?? .zero
        inflationMode = try container.decodeIfPresent(InflationMode.self, forKey: .inflationMode) ?? .organic
    }
}
