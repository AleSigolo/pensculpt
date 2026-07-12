import XCTest
import simd
@testable import PenSculpt

final class MultiPartInflationTests: XCTestCase {

    private func makeStroke(points: [CGPoint]) -> Stroke {
        Stroke(points: points.enumerated().map { i, p in
            StrokePoint(location: p, pressure: 1, tilt: 0, azimuth: 0,
                        timestamp: TimeInterval(i) * 0.01)
        })
    }

    private func circleStroke(center: CGPoint, radius: CGFloat, steps: Int = 64) -> Stroke {
        makeStroke(points: (0...steps).map { i in
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: center.x + radius * cos(angle),
                           y: center.y + radius * sin(angle))
        })
    }

    /// Snowman: overlapping head (r=35) and body (r=60), centers 90 apart.
    /// Each part must puff to its own scale — head shallower than body.
    func testPerPartDepthIndependence() {
        let head = circleStroke(center: CGPoint(x: 200, y: 100), radius: 35)
        let body = circleStroke(center: CGPoint(x: 200, y: 190), radius: 60)
        let mesh = ShapeInflater.inflate(strokes: [head, body])
        XCTAssertFalse(mesh.isEmpty)

        // World y = −canvas y (ShapeInflater negates y in buildMesh).
        func maxZ(nearCanvasY canvasY: Float, tolerance: Float) -> Float {
            mesh.vertices
                .filter { abs($0.position.y - (-canvasY)) < tolerance &&
                          abs($0.position.x - 200) < tolerance }
                .map(\.position.z).max() ?? 0
        }
        let headDepth = maxZ(nearCanvasY: 100, tolerance: 10)
        let bodyDepth = maxZ(nearCanvasY: 190, tolerance: 10)

        XCTAssertGreaterThan(headDepth, 25)
        XCTAssertGreaterThan(bodyDepth, headDepth,
            "Body (r=60) must puff deeper than head (r=35): head=\(headDepth) body=\(bodyDepth)")
        // Under the old single-contour global maxDist the head center would
        // reach ≈ sqrt(35·(2·60−35)) ≈ 55. Per-part profile keeps it near 35.
        XCTAssertLessThan(headDepth, 45,
            "Head must keep its own spherical scale, got \(headDepth)")
    }

    /// An open stroke inside the silhouette is decoration — identical mesh.
    func testOpenStrokeAddsNoVolume() {
        let circle = circleStroke(center: CGPoint(x: 150, y: 150), radius: 100)
        let chord = makeStroke(points: (0...30).map {
            CGPoint(x: 100 + CGFloat($0) * 3, y: 150)
        })
        let with = ShapeInflater.inflate(strokes: [circle, chord])
        let without = ShapeInflater.inflate(strokes: [circle])
        // Exact equality is deterministic here: the chord lies inside the circle's
        // bbox (identical grid) and the circle is the only part, so smoothMax is
        // never called and the depth fields are bit-identical.
        XCTAssertEqual(with, without,
            "Open decoration ink inside the silhouette must not change the volume")
    }

    /// A part fully inside a deeper host adds volume only where it exceeds
    /// the host — a shallow inner circle must not crater or change anything.
    func testInnerPartDoesNotCraterHost() {
        let torso = circleStroke(center: CGPoint(x: 150, y: 150), radius: 60)
        let belly = circleStroke(center: CGPoint(x: 150, y: 150), radius: 15)
        let with = ShapeInflater.inflate(strokes: [torso, belly])
        let without = ShapeInflater.inflate(strokes: [torso])
        // Exact equality is deterministic: in every belly cell the torso depth
        // (≥ ~58) exceeds belly depth (≤ 15) by more than partBlendRadius, so
        // smoothMax's h clamps to exactly 0 and returns the torso depth bit-exactly.
        XCTAssertEqual(with, without,
            "A shallow part inside a deep host must be absorbed, not cratered")
    }

    /// partBlendRadius = 0 degrades to a hard max — still valid geometry.
    func testHardMaxWithZeroBlendRadius() {
        var config = SculptConfig.default
        config.partBlendRadius = 0
        let head = circleStroke(center: CGPoint(x: 200, y: 100), radius: 35)
        let body = circleStroke(center: CGPoint(x: 200, y: 190), radius: 60)
        let mesh = ShapeInflater.inflate(strokes: [head, body], config: config)
        XCTAssertFalse(mesh.isEmpty)
        assertMeshValid(mesh)
    }

    /// Two circles drawn apart: one object, two shells — still a valid mesh.
    func testDisjointPartsProduceValidMesh() {
        let a = circleStroke(center: CGPoint(x: 100, y: 100), radius: 40)
        let b = circleStroke(center: CGPoint(x: 300, y: 100), radius: 40)
        let mesh = ShapeInflater.inflate(strokes: [a, b])
        XCTAssertFalse(mesh.isEmpty)
        assertMeshValid(mesh)
        // Both shells present: vertices near both centers
        XCTAssertTrue(mesh.vertices.contains { abs($0.position.x - 100) < 10 })
        XCTAssertTrue(mesh.vertices.contains { abs($0.position.x - 300) < 10 })
    }

    /// An outline sketched as two open half-circles: no stroke closes, so the
    /// whole drawing takes the Vision single-contour fallback (old behavior).
    func testMultiArcOutlineFallsBackToSingleContour() {
        let steps = 40
        let top = makeStroke(points: (0...steps).map { i in
            let angle = CGFloat.pi * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: 200 + 100 * cos(angle), y: 200 - 100 * sin(angle))
        })
        let bottom = makeStroke(points: (0...steps).map { i in
            let angle = CGFloat.pi * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: 200 - 100 * cos(angle), y: 200 + 100 * sin(angle))
        })
        let mesh = ShapeInflater.inflate(strokes: [top, bottom])
        XCTAssertFalse(mesh.isEmpty, "Fallback must still inflate multi-arc outlines")
        assertMeshValid(mesh)
    }

    /// Snowman mesh obeys the downstream invariants: valid indices, unit
    /// normals, no NaNs, and a welded rim at z = 0.
    func testCompoundMeshObeysInvariants() {
        let head = circleStroke(center: CGPoint(x: 200, y: 100), radius: 35)
        let body = circleStroke(center: CGPoint(x: 200, y: 190), radius: 60)
        let mesh = ShapeInflater.inflate(strokes: [head, body])
        assertMeshValid(mesh)
        XCTAssertTrue(mesh.vertices.contains { $0.position.z == 0 },
                      "Compound mesh must keep the welded z=0 rim")
        let maxZ = mesh.vertices.map(\.position.z).max()!
        let minZ = mesh.vertices.map(\.position.z).min()!
        XCTAssertGreaterThan(maxZ, 0)
        XCTAssertLessThan(minZ, 0)
    }

    private func assertMeshValid(_ mesh: Mesh, file: StaticString = #filePath, line: UInt = #line) {
        let maxIdx = UInt32(mesh.vertexCount)
        for face in mesh.faces {
            XCTAssertLessThan(face.indices.x, maxIdx, file: file, line: line)
            XCTAssertLessThan(face.indices.y, maxIdx, file: file, line: line)
            XCTAssertLessThan(face.indices.z, maxIdx, file: file, line: line)
        }
        for v in mesh.vertices {
            XCTAssertFalse(v.position.x.isNaN || v.position.y.isNaN || v.position.z.isNaN,
                           "NaN position", file: file, line: line)
            XCTAssertEqual(simd_length(v.normal), 1.0, accuracy: 0.1,
                           "Normals must be ~unit length", file: file, line: line)
        }
    }
}
