import XCTest
import simd
@testable import PenSculpt

final class StrokeLifterTests: XCTestCase {

    private let identity = simd_quatf(vector: SIMD4(0, 0, 0, 1))

    /// A flat quad spanning canvas x in `xRange`, y in 0...100, at world z = 5,
    /// two triangles wound so the geometric winding normal (cross(e1, e2)) is
    /// −z — the viewer-facing winding (ShapeInflater front-sheet convention)
    /// that the `a < -1e-6` cull accepts for a −z ray (see "Picking-ray
    /// conventions" in the plan header).
    private func quad(xRange: ClosedRange<Float>, baseIndex: UInt32 = 0)
        -> (vertices: [MeshVertex], faces: [MeshFace]) {
        let lo = xRange.lowerBound, hi = xRange.upperBound
        let vertices = [
            MeshVertex(position: SIMD3(lo, 0, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(hi, 0, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(hi, -100, 5), normal: SIMD3(0, 0, 1)),
            MeshVertex(position: SIMD3(lo, -100, 5), normal: SIMD3(0, 0, 1)),
        ]
        let faces = [
            MeshFace(indices: SIMD3(baseIndex, baseIndex + 1, baseIndex + 2)),
            MeshFace(indices: SIMD3(baseIndex, baseIndex + 2, baseIndex + 3)),
        ]
        return (vertices, faces)
    }

    /// A flat square 100×100 (canvas coords 0...100) at world z = 5.
    private func makeFlatMesh() -> Mesh {
        let q = quad(xRange: 0...100)
        return Mesh(vertices: q.vertices, faces: q.faces)
    }

    /// Two quads (x 0...40 and x 60...100) with a gap between them.
    private func makeGappedMesh() -> Mesh {
        let left = quad(xRange: 0...40)
        let right = quad(xRange: 60...100, baseIndex: 4)
        return Mesh(vertices: left.vertices + right.vertices,
                    faces: left.faces + right.faces)
    }

    private func makeStroke(_ locations: [CGPoint], pressure: CGFloat = 1,
                            color: CodableColor = .black) -> Stroke {
        Stroke(points: locations.enumerated().map { i, loc in
            StrokePoint(location: loc, pressure: pressure, tilt: .pi / 2,
                        azimuth: 0, timestamp: Double(i) * 0.01)
        }, color: color)
    }

    private func lift(_ strokes: [Stroke], onto mesh: Mesh, offset: Float,
                      maxTJump: Float = 50)
        -> (lifted: [SurfaceStroke], unliftedStrokeIDs: Set<UUID>) {
        StrokeLifter.lift(strokes, bvh: MeshBVH(mesh: mesh),
                          offset: offset, maxTJump: maxTJump)
    }

    // MARK: - Lift

    func testLiftProjectsOntoMeshAlongMinusZ() {
        let mesh = makeFlatMesh()
        let stroke = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1)
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points.count, 2)
        // Canvas (20, 30) → world (20, -30, 5 + offset)
        XCTAssertEqual(lifted[0].points[0].x, 20, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[0].y, -30, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[0].z, 5.5, accuracy: 0.01)
        // pressure 1 → width 8 (inverse of the width/8 bake convention)
        XCTAssertEqual(lifted[0].widths[0], 8, accuracy: 0.01)
        XCTAssertEqual(lifted[0].color, stroke.color)
        // Color already carries alpha; session opacity starts neutral.
        XCTAssertEqual(lifted[0].opacity, 1, accuracy: 1e-6)
    }

    func testLiftDropsIsolatedOffMeshPoints() {
        let mesh = makeFlatMesh()
        // One stray point far off the 100×100 mesh among 25 on it: the
        // stray drops, the stroke still lifts (coverage stays above the
        // no-ink-loss threshold).
        let onMesh = stride(from: 2, through: 98, by: 4).map { CGPoint(x: CGFloat($0), y: 50) }
        let stroke = makeStroke(onMesh + [CGPoint(x: 500, y: 500)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted.count, 1)
        XCTAssertEqual(lifted[0].points.count, onMesh.count)
        XCTAssertTrue(unlifted.isEmpty)
    }

    func testLiftSplitsIntoSegmentsAcrossAGap() {
        let mesh = makeGappedMesh()
        // Dense runs on both quads, one point in the 40...60 gap; coverage
        // stays high, so the stroke lifts split into two segments.
        let left = stride(from: 2, through: 38, by: 2).map { CGPoint(x: CGFloat($0), y: 50) }
        let right = stride(from: 62, through: 98, by: 2).map { CGPoint(x: CGFloat($0), y: 50) }
        let stroke = makeStroke(left + [CGPoint(x: 50, y: 50)] + right)
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 2)
        XCTAssertTrue(unlifted.isEmpty)
        // No bridging chord: each segment holds only its own quad's points.
        XCTAssertEqual(lifted[0].points.count, left.count)
        XCTAssertEqual(lifted[0].points[0].x, 2, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points.last?.x ?? 0, 38, accuracy: 0.01)
        XCTAssertEqual(lifted[1].points.count, right.count)
        XCTAssertEqual(lifted[1].points[0].x, 62, accuracy: 0.01)
        XCTAssertEqual(lifted[1].points.last?.x ?? 0, 98, accuracy: 0.01)
    }

    func testLiftRescuesHairlineMissesNearTheSilhouette() {
        // Mesh spans x 10...90; the middle ink point sits 2pt outside it —
        // like border ink weaving outside the simplified inflation contour
        // on a curve. It must lift (no dashed gaps), keeping its canvas
        // position, with depth taken from the nearby surface.
        let q = quad(xRange: 10...90)
        let mesh = Mesh(vertices: q.vertices, faces: q.faces)
        let stroke = makeStroke([CGPoint(x: 12, y: 50), CGPoint(x: 8, y: 50),
                                 CGPoint(x: 14, y: 50)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1, "hairline miss must not split the stroke")
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points.count, 3)
        XCTAssertEqual(lifted[0].points[1].x, 8, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[1].y, -50, accuracy: 0.01)
        XCTAssertEqual(lifted[0].points[1].z, 5.5, accuracy: 0.01)
    }

    func testLiftRescuesPartContourDeviation() {
        // Multi-part contours are smoothed + simplified stroke centerlines:
        // on real figures they sit 5-8pt inside the ink line over long
        // stretches (a clean accepted circle lifted only 54% of its ink at
        // 4pt tolerance). Ink 6pt outside the mesh must still lift.
        let q = quad(xRange: 10...90)
        let mesh = Mesh(vertices: q.vertices, faces: q.faces)
        let stroke = makeStroke([CGPoint(x: 12, y: 50), CGPoint(x: 4, y: 50),
                                 CGPoint(x: 14, y: 50)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1, "6pt deviation must be rescued, not shredded")
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points.count, 3)
        XCTAssertEqual(lifted[0].points[1].x, 4, accuracy: 0.01, "canvas XY never moves")
    }

    func testLiftMarchesInwardForItsOwnPartRim() {
        // A part-source stroke can deviate 8-16pt outside its inflated rim
        // where the contour smoothing shrank hardest. The ring rescue can't
        // reach that far, but the ink's own interior direction can: rim ink
        // must march toward the stroke's centroid and ride its part instead
        // of staying behind as flat ghost ink while the volume rotates.
        let q = quad(xRange: 10...90)   // mesh: x 10...90, y 0...-100
        let mesh = Mesh(vertices: q.vertices, faces: q.faces)
        // Closed-ish loop around the mesh; left edge bulges to x = -2,
        // 12pt outside the mesh (beyond the 8pt ring, within inward march).
        let loop = [CGPoint(x: 50, y: 5), CGPoint(x: 88, y: 50),
                    CGPoint(x: 50, y: 95), CGPoint(x: -2, y: 50),
                    CGPoint(x: 50, y: 5)]
        let stroke = makeStroke(loop)
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1, "rim ink must ride its part")
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points.count, loop.count)
        XCTAssertEqual(lifted[0].points[3].x, -2, accuracy: 0.01,
                       "canvas XY never moves — only depth comes from the surface")
    }

    func testLiftInwardMarchDoesNotGlueDistantDecoration() {
        // A "Λ" ear far from any mesh: its centroid sits in empty space, so
        // the inward march finds nothing and the stroke stays flat ink.
        let q = quad(xRange: 10...90)
        let mesh = Mesh(vertices: q.vertices, faces: q.faces)
        let ear = makeStroke([CGPoint(x: 200, y: 300), CGPoint(x: 230, y: 240),
                              CGPoint(x: 260, y: 300)])
        let (lifted, unlifted) = lift([ear], onto: mesh, offset: 0.5)

        XCTAssertTrue(lifted.isEmpty)
        XCTAssertEqual(unlifted, [ear.id])
    }

    func testLiftToleranceStillDropsClearMisses() {
        // 20pt outside the mesh is beyond the ring AND beyond what the
        // inward march can reach: the point stays dropped, coverage falls
        // below the threshold, and the whole stroke stays flat (preserved).
        let q = quad(xRange: 10...90)
        let mesh = Mesh(vertices: q.vertices, faces: q.faces)
        let stroke = makeStroke([CGPoint(x: 12, y: 50), CGPoint(x: -10, y: 50),
                                 CGPoint(x: 14, y: 50)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertTrue(lifted.isEmpty)
        XCTAssertEqual(unlifted, [stroke.id])
    }

    // MARK: - No-ink-loss guarantee

    func testPartiallyCoveredStrokeStaysFlatInsteadOfLosingInk() {
        // Half the stroke crosses the mesh, half extends far beyond it (a
        // rejected part's ink grazing a neighboring part). Lifting only the
        // covered half would DELETE the rest at commit — the original is
        // replaced by the partial projection. Below the coverage threshold
        // the whole stroke must stay flat (reported unlifted), preserved.
        let mesh = makeFlatMesh()   // spans x 0...100
        let onMesh = stride(from: 10, through: 90, by: 10).map { CGPoint(x: CGFloat($0), y: 50) }
        let offMesh = stride(from: 300, through: 380, by: 10).map { CGPoint(x: CGFloat($0), y: 50) }
        let stroke = makeStroke(onMesh + offMesh)   // 9 on + 9 off = 50% coverage
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertTrue(lifted.isEmpty,
                      "a half-covered stroke must not ride the mesh partially")
        XCTAssertEqual(unlifted, [stroke.id],
                       "it must be reported unlifted so commit preserves it")
    }

    func testNearFullCoverageStillLifts() {
        // Losing a couple of feather-tip points is fine — only meaningful
        // partial coverage should demote a stroke to flat ink.
        let mesh = makeFlatMesh()
        let onMesh = stride(from: 2, through: 98, by: 2).map { CGPoint(x: CGFloat($0), y: 50) }
        let stroke = makeStroke(onMesh + [CGPoint(x: 400, y: 400)])   // 49/50 = 98%
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1)
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points.count, 49)
    }

    func testLiftSmoothsDepthSpikesFromSilhouetteCliffs() {
        // Border ink rides the inflated mesh's near-vertical rim, where
        // adjacent rays alternate between the rounded top and partway down
        // the cliff — raw hit depths zigzag by tens of points and the lifted
        // line "serpentines" the moment the object rotates. Simulate with a
        // thin tall ridge: a stroke crossing it must come out with smooth
        // depth, and its canvas XY must be untouched.
        let left = quad(xRange: 0...14)
        var ridge = quad(xRange: 14...16, baseIndex: 4)
        ridge.vertices = ridge.vertices.map {
            MeshVertex(position: SIMD3($0.position.x, $0.position.y, 25),
                       normal: $0.normal)
        }
        let right = quad(xRange: 16...30, baseIndex: 8)
        let mesh = Mesh(vertices: left.vertices + ridge.vertices + right.vertices,
                        faces: left.faces + ridge.faces + right.faces)

        let xs: [CGFloat] = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29]
        let stroke = makeStroke(xs.map { CGPoint(x: $0, y: 50) })
        let (lifted, _) = lift([stroke], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 1)
        XCTAssertEqual(lifted[0].points.count, xs.count)
        for (i, p) in lifted[0].points.enumerated() {
            XCTAssertEqual(p.x, Float(xs[i]), accuracy: 0.01, "XY must never change")
            XCTAssertEqual(p.y, -50, accuracy: 0.01, "XY must never change")
        }
        // The single-sample 20pt spike at x=15 must be flattened away.
        for i in 1..<lifted[0].points.count {
            let dz = abs(lifted[0].points[i].z - lifted[0].points[i - 1].z)
            XCTAssertLessThan(dz, 4, "depth still jumps \(dz)pt between samples \(i-1) and \(i)")
        }
    }

    func testLiftReportsFullyMissingStrokeAsUnlifted() {
        let mesh = makeFlatMesh()
        let stroke = makeStroke([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 600)])
        let (lifted, unlifted) = lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertTrue(lifted.isEmpty)
        XCTAssertEqual(unlifted, [stroke.id])
    }

    func testLiftMultipleStrokesPreservesOrder() {
        let mesh = makeFlatMesh()
        let first = makeStroke([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10)])
        let second = makeStroke([CGPoint(x: 70, y: 90), CGPoint(x: 80, y: 90)])
        let (lifted, unlifted) = lift([first, second], onto: mesh, offset: 0.5)

        XCTAssertEqual(lifted.count, 2)
        XCTAssertTrue(unlifted.isEmpty)
        XCTAssertEqual(lifted[0].points[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(lifted[1].points[0].x, 70, accuracy: 0.01)
    }

    func testBakeReunitesSegmentsOfTheSameSourceStroke() {
        // A stroke that lifts split (mesh gap / t-jump) bakes back as ONE 2D
        // stroke, not several invisibly "perforated" pieces — the vector
        // eraser removes whole strokes, so hidden seams make a single touch
        // erase only a fragment of what the user drew as one line.
        let mesh = makeGappedMesh()
        let left = stride(from: 2, through: 38, by: 2).map { CGPoint(x: CGFloat($0), y: 50) }
        let right = stride(from: 62, through: 98, by: 2).map { CGPoint(x: CGFloat($0), y: 50) }
        let stroke = makeStroke(left + [CGPoint(x: 50, y: 50)] + right)
        let (lifted, _) = lift([stroke], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted.count, 2, "fixture must produce a split lift")

        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))

        XCTAssertEqual(baked.count, 1, "same-source segments must bake as one stroke")
        XCTAssertEqual(baked[0].points.count, left.count + right.count)
        XCTAssertEqual(baked[0].points.first?.location.x ?? 0, 2, accuracy: 0.1)
        XCTAssertEqual(baked[0].points.last?.location.x ?? 0, 98, accuracy: 0.1)
    }

    func testBakeKeepsIndependentStrokesSeparate() {
        // Segments with different origins (two pen strokes drawn on the
        // mesh) must NOT be welded, even when their ends sit close.
        let mesh = makeFlatMesh()
        let a = makeStroke([CGPoint(x: 10, y: 50), CGPoint(x: 40, y: 50)])
        let b = makeStroke([CGPoint(x: 44, y: 50), CGPoint(x: 80, y: 50)])
        let (lifted, _) = lift([a, b], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted.count, 2)

        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked.count, 2)
    }

    // MARK: - Bake

    func testBakeAtIdentityRoundTripsLift() {
        let mesh = makeFlatMesh()
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)])
        let (lifted, _) = lift([original], onto: mesh, offset: 0.5)
        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked.count, 1)
        XCTAssertEqual(baked[0].points[0].location.x, 20, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[0].location.y, 30, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[1].location.x, 60, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[1].location.y, 70, accuracy: 0.05)
        XCTAssertEqual(baked[0].points[0].pressure, 1, accuracy: 0.05)
    }

    func testRoundTripPreservesHalfPressure() {
        let mesh = makeFlatMesh()
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)],
                                  pressure: 0.5)
        let (lifted, _) = lift([original], onto: mesh, offset: 0.5)
        XCTAssertEqual(lifted[0].widths[0], 4, accuracy: 0.01)
        let baked = StrokeLifter.bake(lifted, orientation: identity, scale: 1,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked[0].points[0].pressure, 0.5, accuracy: 0.001)
    }

    func testTranslucentRoundTripFoldsOpacityIntoAlpha() {
        let mesh = makeFlatMesh()
        let translucent = CodableColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        let original = makeStroke([CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 70)],
                                  color: translucent)
        let (lifted, _) = lift([original], onto: mesh, offset: 0.5)
        // Lift must not double-count alpha into opacity.
        XCTAssertEqual(lifted[0].opacity, 1, accuracy: 1e-6)
        XCTAssertEqual(lifted[0].color.alpha, 0.5, accuracy: 1e-6)

        // A session that halved the stroke's opacity bakes to alpha 0.25.
        var faded = lifted[0]
        faded.opacity = 0.5
        let baked = StrokeLifter.bake([faded], orientation: identity, scale: 1,
                                      pivot: .zero)
        XCTAssertEqual(baked[0].color.alpha, 0.25, accuracy: 1e-6)
    }

    func testBakeHalfTurnAboutYMirrorsXAboutPivot() {
        let ss = SurfaceStroke(points: [SIMD3(60, -50, 0)], widths: [8], color: .black)
        // Single-point strokes are legal input for bake (min length is enforced at lift).
        let baked = StrokeLifter.bake([ss],
                                      orientation: simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)),
                                      scale: 1, pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked[0].points[0].location.x, 40, accuracy: 0.01)
        XCTAssertEqual(baked[0].points[0].location.y, 50, accuracy: 0.01)
    }

    func testBakeAtScaleTwoDoublesPositionAndPressure() {
        // On screen the strip is scaled by the model matrix, so WYSIWYG bake
        // must scale both position about the pivot and rendered width.
        let ss = SurfaceStroke(points: [SIMD3(60, -50, 0)], widths: [8], color: .black)
        let baked = StrokeLifter.bake([ss], orientation: identity, scale: 2,
                                      pivot: SIMD3(50, -50, 0))
        XCTAssertEqual(baked[0].points[0].location.x, 70, accuracy: 0.01)
        XCTAssertEqual(baked[0].points[0].location.y, 50, accuracy: 0.01)
        XCTAssertEqual(baked[0].points[0].pressure, 2, accuracy: 0.001)
    }

    func testBakePreservesColor() {
        let blue = CodableColor(red: 0.2, green: 0.2, blue: 0.8, alpha: 1)
        let ss = SurfaceStroke(points: [SIMD3(10, -10, 0), SIMD3(20, -20, 0)],
                               widths: [8, 8], color: blue)
        let baked = StrokeLifter.bake([ss], orientation: identity, scale: 1, pivot: .zero)
        XCTAssertEqual(baked[0].color, blue)
    }
}
