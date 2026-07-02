import CoreGraphics
import simd

/// In-place camera for 2.5D edit mode.
///
/// World space is canvas space with y negated (see ShapeInflater). The
/// orthographic projection spans the full view so a world point (x, -y, 0)
/// renders exactly at canvas point (x, y) — this is what makes lift-off
/// visually seamless. Rotation and uniform scale are a model transform
/// pivoting at `center` (the object's world-space center).
struct CameraTransform: Equatable {
    var viewSize: CGSize
    var center: SIMD3<Float>
    var orientation: simd_quatf = simd_quatf(vector: SIMD4(0, 0, 0, 1))
    var scale: Float = 1

    /// Depth range generously covering any inflated mesh (depth <= shape size / 2).
    private static let depthRange: Float = 4096

    var projectionMatrix: simd_float4x4 {
        Self.orthographic(left: 0, right: Float(viewSize.width),
                          bottom: -Float(viewSize.height), top: 0,
                          near: -Self.depthRange, far: Self.depthRange)
    }

    var modelMatrix: simd_float4x4 {
        Self.modelMatrix(center: center, orientation: orientation, scale: scale)
    }

    /// Projection * model. There is no separate view matrix — the camera never moves.
    var mvpMatrix: simd_float4x4 { projectionMatrix * modelMatrix }

    /// MVP for flat canvas-plane content (in-progress 2D strokes): projection only.
    var canvasMVP: simd_float4x4 { projectionMatrix }

    static func modelMatrix(center: SIMD3<Float>, orientation: simd_quatf,
                            scale: Float) -> simd_float4x4 {
        translation(center) * simd_float4x4(orientation) * scaleMatrix(scale) * translation(-center)
    }

    func worldToScreen(_ p: SIMD3<Float>) -> CGPoint {
        let clip = mvpMatrix * SIMD4<Float>(p.x, p.y, p.z, 1)
        let ndcX = clip.x / clip.w
        let ndcY = clip.y / clip.w
        return CGPoint(x: CGFloat((ndcX + 1) / 2) * viewSize.width,
                       y: CGFloat((1 - ndcY) / 2) * viewSize.height)
    }

    /// Unprojects a screen point into a world-space picking ray. The origin sits
    /// on the near plane (NDC z = 0, the viewer side at world z = +depthRange)
    /// and the ray travels −z through the scene, so smallest hit t is nearest
    /// the viewer — same convention as SculptRenderer.hitTest, and the winding
    /// MeshBVH.raycast's `a < -1e-6` cull accepts is the viewer-facing sheet
    /// of a ShapeInflater mesh (geometric winding normal −z).
    func ray(from screenPoint: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let inv = mvpMatrix.inverse
        let ndcX = Float(2 * screenPoint.x / viewSize.width - 1)
        let ndcY = Float(1 - 2 * screenPoint.y / viewSize.height)
        let o4 = inv * SIMD4<Float>(ndcX, ndcY, 0, 1)
        let t4 = inv * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let o = SIMD3(o4.x, o4.y, o4.z) / o4.w
        let t = SIMD3(t4.x, t4.y, t4.z) / t4.w
        return (o, normalize(t - o))
    }

    /// Applies the model transform to a world point (used by StrokeLifter.bake).
    func modelTransformed(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = modelMatrix * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    // MARK: - Matrix builders

    /// Orthographic projection with glOrtho parameter semantics but Metal's
    /// clip volume: the viewer looks down −z, `near`/`far` are signed distances
    /// along the view direction, and view-space z ∈ [−near, −far] maps to
    /// depth [0, 1] (Metal clips z_ndc to [0, 1], NOT OpenGL's [−1, +1]).
    /// With the usual call near = −R, far = +R this makes the whole slab
    /// z ∈ [−R, +R] visible and puts larger world z NEARER the viewer
    /// (viewer at +z) — verified on the GPU by MetalConventionTests.
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float,
                             near: Float, far: Float) -> simd_float4x4 {
        let sx = 2.0 / (right - left)
        let sy = 2.0 / (top - bottom)
        let sz = -1.0 / (far - near)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        let tz = -near / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, sz, 0),
            SIMD4<Float>(tx, ty, tz, 1)
        ))
    }

    static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(v.x, v.y, v.z, 1)
        ))
    }

    static func scaleMatrix(_ s: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(s, 0, 0, 0),
            SIMD4<Float>(0, s, 0, 0),
            SIMD4<Float>(0, 0, s, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
