import CoreGraphics
import Foundation
import simd

/// Moves ink between the flat canvas and a sculpt object's surface.
///
/// `lift` runs on entry to 2.5D edit mode: source 2D strokes are ray-cast
/// along -z onto the mesh so the drawing rides on the object. `bake` runs on
/// exit: all surface ink is projected through the session's model transform
/// and flattened back to 2D strokes — what you see at commit is what stays.
enum StrokeLifter {

    /// Canvas-pressure ↔ world-width conversion, matching StrokeConverter's
    /// `size = pressure * 8` and SurfaceStroke.projectTo2D's `pressure = width / 8`.
    static let widthPerPressure: Float = 8

    /// Projects `strokes` onto the mesh with −z rays from the viewer side
    /// (same convention as SculptRenderer.hitTest — see "Picking-ray
    /// conventions" in the plan header; hits are nudged +z toward the viewer
    /// by `offset`).
    ///
    /// A stroke splits into a new SurfaceStroke segment whenever a point
    /// misses the mesh or the hit distance jumps by `maxTJump` or more
    /// (matching live-draw's surfaceStrokeMaxTJump behavior) — gaps are never
    /// bridged with a straight chord. Segments with fewer than two points are
    /// dropped. Source strokes contributing zero segments are reported in
    /// `unliftedStrokeIDs` so commit can carry them through unmodified
    /// instead of deleting them.
    static func lift(_ strokes: [Stroke], onto mesh: Mesh, bvh: MeshBVH,
                     offset: Float, maxTJump: Float = 50)
        -> (lifted: [SurfaceStroke], unliftedStrokeIDs: Set<UUID>) {
        let direction = SIMD3<Float>(0, 0, -1)
        var lifted: [SurfaceStroke] = []
        var unliftedStrokeIDs: Set<UUID> = []

        for stroke in strokes {
            var producedSegment = false
            var points: [SIMD3<Float>] = []
            var widths: [Float] = []
            var lastT: Float = 0

            func flushSegment() {
                if points.count > 1 {
                    // opacity stays 1: color already carries the stroke's alpha,
                    // and bake folds session opacity into it (never double-count).
                    lifted.append(SurfaceStroke(points: points, widths: widths,
                                                opacity: 1, color: stroke.color))
                    producedSegment = true
                }
                points = []
                widths = []
            }

            for sp in stroke.points {
                let origin = SIMD3<Float>(Float(sp.location.x), Float(-sp.location.y), 4096)
                guard let (t, _) = bvh.raycast(origin: origin, direction: direction) else {
                    flushSegment()
                    continue
                }
                if !points.isEmpty && abs(t - lastT) >= maxTJump {
                    flushSegment()
                }
                points.append(origin + t * direction - direction * offset)
                widths.append(Float(sp.pressure) * widthPerPressure)
                lastT = t
            }
            flushSegment()

            if !producedSegment { unliftedStrokeIDs.insert(stroke.id) }
        }
        return (lifted, unliftedStrokeIDs)
    }

    static func bake(_ surfaceStrokes: [SurfaceStroke], orientation: simd_quatf,
                     scale: Float, pivot: SIMD3<Float>) -> [Stroke] {
        let model = CameraTransform.modelMatrix(center: pivot, orientation: orientation,
                                                scale: scale)
        return surfaceStrokes.compactMap { ss in
            guard !ss.points.isEmpty else { return nil }
            let strokePoints = ss.points.enumerated().map { i, p -> StrokePoint in
                let v = model * SIMD4<Float>(p.x, p.y, p.z, 1)
                let width = i < ss.widths.count ? ss.widths[i] : widthPerPressure
                return StrokePoint(
                    location: CGPoint(x: CGFloat(v.x), y: CGFloat(-v.y)),
                    // WYSIWYG: on screen the strip is scaled by the model
                    // matrix, so the baked ink width is width × scale.
                    pressure: CGFloat(width * scale / widthPerPressure),
                    tilt: .pi / 2,
                    azimuth: 0,
                    timestamp: TimeInterval(i) * 0.01
                )
            }
            // Fold session opacity into the color's alpha, like projectTo2D.
            let color = CodableColor(red: ss.color.red, green: ss.color.green,
                                     blue: ss.color.blue,
                                     alpha: ss.color.alpha * CGFloat(ss.opacity))
            return Stroke(points: strokePoints, color: color)
        }
    }
}
