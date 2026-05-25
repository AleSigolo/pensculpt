import XCTest
import simd
@testable import PenSculpt

final class SculptRendererProjectionTests: XCTestCase {

    func testPerspectiveProjectionPlacesCenterAtNDCOrigin() {
        // A point on the camera forward axis (any z in the frustum) should
        // project to NDC xy = (0, 0) regardless of FOV.
        let m = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 4,  // 45°
            aspect: 1.5,
            near: 1.0,
            far: 100.0
        )
        // Camera looks down -Z; this point is 10 units in front of camera.
        let p = SIMD4<Float>(0, 0, -10, 1)
        let clip = m * p
        let ndc = SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
        XCTAssertEqual(ndc.x, 0, accuracy: 1e-5)
        XCTAssertEqual(ndc.y, 0, accuracy: 1e-5)
    }

    func testPerspectiveProjectionRespectsAspect() {
        // Same world-space horizontal extent should produce smaller |x_ndc|
        // when aspect (w/h) > 1 because the frustum is wider.
        let mSquare = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 4, aspect: 1.0, near: 1.0, far: 100.0
        )
        let mWide = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 4, aspect: 2.0, near: 1.0, far: 100.0
        )
        let p = SIMD4<Float>(1, 0, -10, 1)
        let xSquare = (mSquare * p).x / (mSquare * p).w
        let xWide = (mWide * p).x / (mWide * p).w
        XCTAssertGreaterThan(abs(xSquare), abs(xWide),
                             "wider aspect should pull x_ndc toward zero")
    }

    func testPerspectiveProjectionFOVAffectsZoom() {
        // Wider FOV at same point means smaller |x_ndc| (object appears smaller).
        let m30 = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 6, aspect: 1.0, near: 1.0, far: 100.0
        )
        let m90 = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 2, aspect: 1.0, near: 1.0, far: 100.0
        )
        let p = SIMD4<Float>(1, 0, -10, 1)
        let x30 = (m30 * p).x / (m30 * p).w
        let x90 = (m90 * p).x / (m90 * p).w
        XCTAssertGreaterThan(abs(x30), abs(x90),
                             "narrower FOV magnifies, wider FOV shrinks")
    }

    func testPerspectiveProjectionMapsZToGLNDC() {
        // GL convention: a point on the near plane (z_view = -near) maps to
        // NDC z = -1; a point on the far plane (z_view = -far) maps to NDC z = 1.
        // This matches orthographicProjection so the two can be lerped.
        let m = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 4, aspect: 1.0, near: 1.0, far: 100.0
        )
        let onNear = SIMD4<Float>(0, 0, -1.0, 1)
        let onFar = SIMD4<Float>(0, 0, -100.0, 1)
        let zNear = (m * onNear).z / (m * onNear).w
        let zFar = (m * onFar).z / (m * onFar).w
        XCTAssertEqual(zNear, -1, accuracy: 1e-5,
                       "near plane should map to NDC z = -1 (GL convention)")
        XCTAssertEqual(zFar, 1, accuracy: 1e-5,
                       "far plane should map to NDC z = 1 (GL convention)")
    }

    func testCombinedProjectionAtTransitionZeroEqualsOrtho() {
        // Regression check: with projectionTransition = 0, output equals the
        // pre-feature orthographic projection so existing scenes don't shift.
        let renderer = SculptRenderer.makeForTesting()
        renderer.setCombinedBoundsForTesting(center: .zero, radius: 1.0)
        renderer.projectionTransition = 0.0

        let mvp = renderer.combinedProjection(viewSize: CGSize(width: 200, height: 100))

        // A point at (1, 0, 0) in world space, with zero rotation, maps to
        // x_ndc = 1 / (combinedRadius * aspect) under the existing ortho.
        let p = SIMD4<Float>(1, 0, 0, 1)
        let clip = mvp * p
        let x_ndc = clip.x / clip.w
        XCTAssertEqual(x_ndc, 0.5, accuracy: 1e-4,
                       "ortho with r=1, aspect=2 puts x=1 at NDC 0.5")
    }

    func testCombinedProjectionAtTransitionOneIsPurePerspective() {
        // With projectionTransition = 1, MVP equals the perspective matrix
        // composed with view (rotation + translation).
        let renderer = SculptRenderer.makeForTesting()
        renderer.setCombinedBoundsForTesting(center: .zero, radius: 1.0)
        renderer.projectionTransition = 1.0
        renderer.perspectiveFOV = .pi / 4

        let mvp = renderer.combinedProjection(viewSize: CGSize(width: 100, height: 100))
        // A point at world origin maps to NDC (0, 0) under both modes.
        let p = SIMD4<Float>(0, 0, 0, 1)
        let clip = mvp * p
        XCTAssertEqual(clip.x / clip.w, 0, accuracy: 1e-3)
        XCTAssertEqual(clip.y / clip.w, 0, accuracy: 1e-3)
    }

    func testCombinedProjectionInterpolatesLinearly() {
        // At transition = 0.5, each component of the resulting matrix should
        // be the average of the two endpoints.
        let renderer = SculptRenderer.makeForTesting()
        renderer.setCombinedBoundsForTesting(center: .zero, radius: 1.0)
        renderer.perspectiveFOV = .pi / 4

        renderer.projectionTransition = 0.0
        let mOrtho = renderer.combinedProjection(viewSize: CGSize(width: 100, height: 100))

        renderer.projectionTransition = 1.0
        let mPersp = renderer.combinedProjection(viewSize: CGSize(width: 100, height: 100))

        renderer.projectionTransition = 0.5
        let mMid = renderer.combinedProjection(viewSize: CGSize(width: 100, height: 100))

        for col in 0..<4 {
            for row in 0..<4 {
                let expected = (mOrtho[col][row] + mPersp[col][row]) * 0.5
                XCTAssertEqual(mMid[col][row], expected, accuracy: 1e-5,
                               "component [\(col)][\(row)] should be the average")
            }
        }
    }
}

// MARK: - Test helpers

extension SculptRenderer {
    static func makeForTesting() -> SculptRenderer {
        let device = MTLCreateSystemDefaultDevice()!
        return SculptRenderer(device: device)!
    }
}
