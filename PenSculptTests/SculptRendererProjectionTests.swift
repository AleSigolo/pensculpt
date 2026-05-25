import XCTest
import simd
@testable import PenSculpt

final class SculptRendererProjectionTests: XCTestCase {

    func testPerspectiveProjectionPlacesCenterAtNDCOrigin() {
        // A point at the camera-space origin (0, 0, -near_distance) should
        // project to (0, 0) in NDC xy regardless of FOV.
        let m = SculptRenderer.perspectiveProjection(
            fovRadians: .pi / 4,  // 45°
            aspect: 1.5,
            near: 1.0,
            far: 100.0
        )
        // Apply matrix to a point right in front of the camera at z = -10.
        // (Conventional Metal: camera looks down -Z.)
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
}
