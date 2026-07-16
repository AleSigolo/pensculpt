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
    /// `size = pressure * 8` (so `pressure = width / 8` on the way back).
    static let widthPerPressure: Float = 8

    /// Projects `strokes` onto the BVH's mesh with −z rays from the viewer
    /// side (same convention as SculptRenderer.hitTest — see "Picking-ray
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
    ///
    /// A miss is retried within `missTolerance` points of the ink position
    /// before splitting: inflation contours are simplified polygons that dip
    /// inside the ink centerline — Vision raster contours by a hair on
    /// curves, and multi-part contours (smoothed + simplified stroke
    /// centerlines) by 5–8pt over long stretches, which shredded even a
    /// clean accepted circle to 54% ink coverage at the old 4pt default.
    /// The default is the rasterized contour ink width
    /// (`contourStrokeWidth`, 8). Rescued points keep their canvas XY —
    /// only depth comes from the nearby surface — so lift registration
    /// stays exact.
    ///
    /// No-ink-loss guarantee: commit DELETES lifted source strokes and
    /// replaces them with the bake of their surface segments — any point
    /// dropped here is user ink destroyed forever. A stroke only lifts when
    /// at least `minCoverage` of its points landed on the mesh; below that
    /// its partial segments are discarded and the stroke is reported
    /// unlifted, so it stays visible flat ink and survives commit untouched
    /// (multi-part meshes routinely leave rejected-part ink half-covering a
    /// neighboring part).
    static func lift(_ strokes: [Stroke], bvh: MeshBVH,
                     offset: Float, maxTJump: Float = 50,
                     missTolerance: Float = 8,
                     minCoverage: Float = 0.95)
        -> (lifted: [SurfaceStroke], unliftedStrokeIDs: Set<UUID>) {
        let direction = SIMD3<Float>(0, 0, -1)
        var lifted: [SurfaceStroke] = []
        var unliftedStrokeIDs: Set<UUID> = []

        for stroke in strokes {
            let segmentsBefore = lifted.count
            var liftedPointCount = 0
            var points: [SIMD3<Float>] = []
            var widths: [Float] = []
            var lastT: Float = 0

            func flushSegment() {
                if points.count > 1 {
                    // opacity stays 1: color already carries the stroke's alpha,
                    // and bake folds session opacity into it (never double-count).
                    lifted.append(SurfaceStroke(points: smoothedDepths(points),
                                                widths: widths,
                                                opacity: 1, color: stroke.color))
                    liftedPointCount += points.count
                }
                points = []
                widths = []
            }

            for sp in stroke.points {
                let x = Float(sp.location.x)
                let y = Float(-sp.location.y)
                guard let t = raycastWithTolerance(x: x, y: y, bvh: bvh,
                                                   tolerance: missTolerance) else {
                    flushSegment()
                    continue
                }
                if !points.isEmpty && abs(t - lastT) >= maxTJump {
                    flushSegment()
                }
                points.append(SIMD3(x, y, 4096 - t + offset))
                widths.append(Float(sp.pressure) * widthPerPressure)
                lastT = t
            }
            flushSegment()

            let coverage = stroke.points.isEmpty
                ? 0 : Float(liftedPointCount) / Float(stroke.points.count)
            if lifted.count == segmentsBefore || coverage < minCoverage {
                lifted.removeSubrange(segmentsBefore...)
                unliftedStrokeIDs.insert(stroke.id)
            }
        }
        return (lifted, unliftedStrokeIDs)
    }

    /// Smooths a lifted segment's DEPTH only — canvas XY is registration and
    /// must never move. Border ink rides the inflated mesh's near-vertical
    /// rim, where adjacent −z rays land alternately on the rounded top and
    /// partway down the cliff: raw hit depths zigzag by tens of points, so
    /// the line "serpentines" as soon as the object rotates (and z-fights
    /// the wall). A moving median (window 5) kills the one-to-two-sample
    /// spikes, then a moving average (window 3) relaxes the tessellation
    /// steps. Windows shrink at segment ends; XY and widths are untouched.
    private static func smoothedDepths(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }

        func filtered(_ zs: [Float], window: Int, reduce: ([Float]) -> Float) -> [Float] {
            let half = window / 2
            return zs.indices.map { i in
                let lo = max(0, i - half), hi = min(zs.count - 1, i + half)
                return reduce(Array(zs[lo...hi]))
            }
        }
        var zs = points.map(\.z)
        zs = filtered(zs, window: 5) { $0.sorted()[$0.count / 2] }
        zs = filtered(zs, window: 3) { $0.reduce(0, +) / Float($0.count) }
        return zip(points, zs).map { SIMD3($0.x, $0.y, $1) }
    }

    /// −z raycast at canvas-world (x, y); on a miss, retries in rings of
    /// growing radius (¼, ½, then full `tolerance`) around the point before
    /// giving up. Returns the hit distance t. Deterministic: fixed direction
    /// order, nearest ring first.
    private static func raycastWithTolerance(x: Float, y: Float, bvh: MeshBVH,
                                             tolerance: Float) -> Float? {
        let direction = SIMD3<Float>(0, 0, -1)
        if let (t, _) = bvh.raycast(origin: SIMD3(x, y, 4096), direction: direction) {
            return t
        }
        guard tolerance > 0 else { return nil }
        let diag: Float = 0.70710678
        let dirs: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1),
            SIMD2(diag, diag), SIMD2(-diag, diag),
            SIMD2(diag, -diag), SIMD2(-diag, -diag),
        ]
        for radius in [tolerance * 0.25, tolerance * 0.5, tolerance] {
            for d in dirs {
                let origin = SIMD3<Float>(x + d.x * radius, y + d.y * radius, 4096)
                if let (t, _) = bvh.raycast(origin: origin, direction: direction) {
                    return t
                }
            }
        }
        return nil
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
            // Fold session opacity into the color's alpha.
            let color = CodableColor(red: ss.color.red, green: ss.color.green,
                                     blue: ss.color.blue,
                                     alpha: ss.color.alpha * CGFloat(ss.opacity))
            return Stroke(points: strokePoints, color: color)
        }
    }
}
