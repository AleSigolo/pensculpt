import XCTest
import simd
@testable import PenSculpt

final class CameraTransformTests: XCTestCase {

    private let identity = simd_quatf(vector: SIMD4(0, 0, 0, 1))

    private func makeCam(orientation: simd_quatf? = nil, scale: Float = 1,
                         center: SIMD3<Float> = SIMD3(500, -400, 0)) -> CameraTransform {
        CameraTransform(viewSize: CGSize(width: 1000, height: 800),
                        center: center,
                        orientation: orientation ?? identity,
                        scale: scale)
    }

    func testIdentityIsPixelRegistered() {
        // World (x, -y, 0) must land at screen/canvas (x, y) — the seamless-entry invariant.
        let cam = makeCam()
        let screen = cam.worldToScreen(SIMD3(250, -300, 0))
        XCTAssertEqual(screen.x, 250, accuracy: 0.01)
        XCTAssertEqual(screen.y, 300, accuracy: 0.01)
    }

    func testPivotIsFixedUnderRotationAndScale() {
        let cam = makeCam(orientation: simd_quatf(angle: 1.2, axis: normalize(SIMD3<Float>(1, 1, 0))),
                          scale: 2.5)
        let screen = cam.worldToScreen(cam.center)
        XCTAssertEqual(screen.x, 500, accuracy: 0.01)
        XCTAssertEqual(screen.y, 400, accuracy: 0.01)
    }

    func testScaleGrowsAboutPivot() {
        let cam = makeCam(scale: 2)
        let screen = cam.worldToScreen(SIMD3(510, -400, 0)) // 10 right of pivot
        XCTAssertEqual(screen.x, 520, accuracy: 0.01)       // now 20 right
        XCTAssertEqual(screen.y, 400, accuracy: 0.01)
    }

    func testHalfTurnAboutYMirrorsX() {
        let cam = makeCam(orientation: simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)))
        let screen = cam.worldToScreen(SIMD3(510, -390, 0))
        XCTAssertEqual(screen.x, 490, accuracy: 0.01)  // mirrored about pivot x
        XCTAssertEqual(screen.y, 390, accuracy: 0.01)  // y unchanged
    }

    func testRayFromScreenPointAtIdentity() {
        // Must reproduce SculptRenderer.hitTest's convention: rays travel +z
        // (NDC z +1 → −1), which is what MeshBVH's `a < -1e-6` cull expects.
        let cam = makeCam()
        let ray = cam.ray(from: CGPoint(x: 123, y: 456))
        XCTAssertEqual(ray.origin.x, 123, accuracy: 0.01)
        XCTAssertEqual(ray.origin.y, -456, accuracy: 0.01)
        XCTAssertEqual(ray.origin.z, -4096, accuracy: 0.5)
        XCTAssertEqual(ray.direction.x, 0, accuracy: 1e-4)
        XCTAssertEqual(ray.direction.y, 0, accuracy: 1e-4)
        XCTAssertEqual(ray.direction.z, 1, accuracy: 1e-4)
    }

    func testModelTransformedMatchesWorldToScreen() {
        // bake() uses modelTransformed; it must agree with what the user saw on screen.
        let cam = makeCam(orientation: simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0)), scale: 1.3)
        let p = SIMD3<Float>(560, -420, 30)
        let viaScreen = cam.worldToScreen(p)
        let m = cam.modelTransformed(p)
        XCTAssertEqual(CGFloat(m.x), viaScreen.x, accuracy: 0.01)
        XCTAssertEqual(CGFloat(-m.y), viaScreen.y, accuracy: 0.01)
    }
}
