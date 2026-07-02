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

    static func lift(_ strokes: [Stroke], onto mesh: Mesh, offset: Float) -> [SurfaceStroke] {
        // Same casting path production uses for re-inference re-projection
        // (SurfaceStroke.reprojected): −z rays from the viewer side with
        // castOntoMesh's `a < -1e-6` cull, which hits the mesh's visible
        // (viewer-facing, winding normal −z) sheet — the same faces
        // SculptRenderer.hitTest picks, with the hit nudged +z toward the
        // viewer by `offset`. castOntoMesh and MeshBVH.raycast now share the
        // same cull, so either works with a −z ray (never cast +z rays here).
        let direction = SIMD3<Float>(0, 0, -1)
        var lifted: [SurfaceStroke] = []

        for stroke in strokes {
            var points: [SIMD3<Float>] = []
            var widths: [Float] = []
            for sp in stroke.points {
                let origin = SIMD3<Float>(Float(sp.location.x), Float(-sp.location.y), 4096)
                guard let (hit, _) = SurfaceStroke.castOntoMesh(
                    from: origin, direction: direction, mesh: mesh, offset: offset) else { continue }
                points.append(hit)
                widths.append(Float(sp.pressure) * widthPerPressure)
            }
            guard points.count > 1 else { continue }
            lifted.append(SurfaceStroke(points: points, widths: widths,
                                        opacity: Float(stroke.color.alpha),
                                        color: stroke.color))
        }
        return lifted
    }

    static func bake(_ surfaceStrokes: [SurfaceStroke], orientation: simd_quatf,
                     scale: Float, pivot: SIMD3<Float>) -> [Stroke] {
        let model = CameraTransform.modelMatrix(center: pivot, orientation: orientation,
                                                scale: scale)
        return surfaceStrokes.compactMap { ss in
            guard !ss.points.isEmpty else { return nil }
            let strokePoints = ss.points.enumerated().map { i, p -> StrokePoint in
                let v = model * SIMD4<Float>(p.x, p.y, p.z, 1)
                return StrokePoint(
                    location: CGPoint(x: CGFloat(v.x), y: CGFloat(-v.y)),
                    pressure: CGFloat((i < ss.widths.count ? ss.widths[i] : widthPerPressure)
                                      / widthPerPressure),
                    tilt: .pi / 2,
                    azimuth: 0,
                    timestamp: TimeInterval(i) * 0.01
                )
            }
            return Stroke(points: strokePoints, color: ss.color)
        }
    }
}
