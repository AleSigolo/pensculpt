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
        // Must reproduce SculptRenderer.hitTest's convention: the origin is on
        // the viewer side (world z = +depthRange, NDC z = 0) and rays travel −z
        // into the scene — the winding MeshBVH's `a < -1e-6` cull accepts is
        // then the viewer-facing sheet of a ShapeInflater mesh.
        let cam = makeCam()
        let ray = cam.ray(from: CGPoint(x: 123, y: 456))
        XCTAssertEqual(ray.origin.x, 123, accuracy: 0.01)
        XCTAssertEqual(ray.origin.y, -456, accuracy: 0.01)
        XCTAssertEqual(ray.origin.z, 4096, accuracy: 0.5)
        XCTAssertEqual(ray.direction.x, 0, accuracy: 1e-4)
        XCTAssertEqual(ray.direction.y, 0, accuracy: 1e-4)
        XCTAssertEqual(ray.direction.z, -1, accuracy: 1e-4)
    }

    func testRayRoundTripsThroughWorldPointUnderRotationAndScale() {
        // For any world/object-space point p, the picking ray cast at
        // worldToScreen(p) must pass through p itself — this is what makes
        // pick-then-draw land exactly under the pen for a rotated object.
        let cam = makeCam(orientation: simd_quatf(angle: 0.9, axis: normalize(SIMD3<Float>(1, 2, 0.5))),
                          scale: 1.7)
        let p = SIMD3<Float>(560, -420, 30)
        let ray = cam.ray(from: cam.worldToScreen(p))
        let toP = p - ray.origin
        // Distance from p to the ray line is ~0, and p lies ahead of the origin.
        let distance = length(cross(toP, ray.direction))
        XCTAssertEqual(distance, 0, accuracy: 0.05)
        XCTAssertGreaterThan(dot(toP, ray.direction), 0,
                             "Ray origin must be on the viewer side of the scene")
    }

    func testPositiveWorldZIsInsideMetalClipVolume() {
        // Regression for the OpenGL-convention ortho matrix: Metal clips NDC z
        // to [0, 1] (not [−1, +1]), so lifted/rotated geometry at world z > 0
        // must stay inside [0, 1] — and be NEARER (smaller depth) than z < 0.
        let proj = makeCam().projectionMatrix
        let front = proj * SIMD4<Float>(500, -400, 4000, 1)
        let back = proj * SIMD4<Float>(500, -400, -4000, 1)
        let frontDepth = front.z / front.w
        let backDepth = back.z / back.w
        XCTAssertGreaterThanOrEqual(frontDepth, 0)
        XCTAssertLessThanOrEqual(frontDepth, 1)
        XCTAssertGreaterThanOrEqual(backDepth, 0)
        XCTAssertLessThanOrEqual(backDepth, 1)
        XCTAssertLessThan(frontDepth, backDepth,
                          "Larger world z must be nearer the viewer (smaller depth)")
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
