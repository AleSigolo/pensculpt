# Multi-Part Inflation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Figures drawn as several closed strokes (circle head, oval body, sausage limbs) inflate as compound 3D volumes — each part puffed to its own scale and united by a smooth-max in the depth field — instead of failing or collapsing into one blob.

**Architecture:** A new `PartExtractor` classifies each stroke as a closed part (endpoint-gap + area tests) and cleans its loop (Laplacian smoothing). `ShapeInflater.inflate` computes one distance field per part on the existing shared grid, applies the spherical profile with a per-part `maxDist`, and combines cells with a polynomial smooth-max. The combined depth grid feeds the **unchanged** `buildMesh`/`subdivideElongatedEdges`, so `Mesh`, `MeshBVH`, `SculptRenderer`, and `StrokeLifter` are untouched. If no stroke closes, the whole drawing falls back to the existing Vision single-contour path.

**Tech Stack:** Swift 5.9, iOS 17, XCTest, xcodegen-generated Xcode project. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-12-multi-part-inflation-design.md`

## Global Constraints

- Swift 5.9, iOS 17.0, iPad only; models `Codable`, `Equatable`, `Sendable` where the neighbors are.
- One test file per source file, in `PenSculptTests/`.
- After adding any new file, run `xcodegen generate` (project is generated from `project.yml`; new files under `PenSculpt/` and `PenSculptTests/` are picked up by directory).
- Build/test destination: `platform=iOS Simulator,name=iPad Pro 13-inch (M5)`.
- Downstream invariants that must not change: output mesh is one welded front/back sheet, front sheet at `z > 0`, geometric winding normal of front faces is −z, indexed triangle soup with freely displaceable vertices.
- Config keys and defaults exactly as specced: `partClosureRatio = 0.2`, `partMinArea = 100`, `partSmoothingPasses = 2`, `partBlendRadius = 10`.
- `ShapeInflater.sculpt(from:config:)` keeps its signature; `originRect` stays the bbox of ALL source stroke points; open strokes stay in `sourceStrokeIDs`.

## File Structure

| File | Action | Responsibility |
| --- | --- | --- |
| `PenSculpt/Drawing/PartExtractor.swift` | Create | `Part` value type; closed-stroke detection, degenerate filtering, loop smoothing/simplification |
| `PenSculpt/Models/SculptConfig.swift` | Modify | Four new tuning knobs |
| `PenSculpt/Drawing/ShapeInflater.swift` | Modify | Per-part distance fields, per-part profile, smooth-max union, fallback branch |
| `PenSculptTests/PartExtractorTests.swift` | Create | Closure/area/smoothing unit tests |
| `PenSculptTests/MultiPartInflationTests.swift` | Create | Compound-inflation behavior tests |
| `PenSculptTests/PipelineVisualTests.swift` | Modify | Multi-part figure diagnostic fixture |
| `TODO.md` | Modify | Feature status line |

---

### Task 1: PartExtractor — closed-stroke detection

**Files:**
- Create: `PenSculpt/Drawing/PartExtractor.swift`
- Modify: `PenSculpt/Models/SculptConfig.swift` (after `contourMaxPoints`, line ~20)
- Test: `PenSculptTests/PartExtractorTests.swift` (create)

**Interfaces:**
- Consumes: `Stroke` (`PenSculpt/Models/Stroke.swift` — `id: UUID`, `points: [StrokePoint]`, `StrokePoint.location: CGPoint`), `SculptConfig`.
- Produces: `struct Part { var contour: [CGPoint]; let sourceStrokeID: UUID }` and `PartExtractor.parts(from: [Stroke], config: SculptConfig) -> [Part]`, plus `PartExtractor.signedArea(_ loop: [CGPoint]) -> CGFloat`. Task 3 calls `parts(from:config:)`; Task 2 extends this file with `smoothed(_:passes:)`.
- Contour convention: the returned `contour` is an **implicitly closed** polygon (last→first edge is implied). This matches `ShapeInflater.containsAndDistance`, which wraps `j = count - 1`, so no explicit closing point is appended.

- [ ] **Step 1: Add config knobs**

In `PenSculpt/Models/SculptConfig.swift`, after the `contourMaxPoints` property:

```swift
    /// A stroke is a closed part when its endpoint gap ≤ ratio × arc length.
    var partClosureRatio: CGFloat = 0.2

    /// Minimum |signed area| in pt² for a closed loop to count as a part.
    /// Rejects back-and-forth scribbles that technically return to their start.
    var partMinArea: CGFloat = 100
```

- [ ] **Step 2: Write the failing tests**

Create `PenSculptTests/PartExtractorTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class PartExtractorTests: XCTestCase {

    private func makeStroke(points: [CGPoint]) -> Stroke {
        Stroke(points: points.enumerated().map { i, p in
            StrokePoint(location: p, pressure: 1, tilt: 0, azimuth: 0,
                        timestamp: TimeInterval(i) * 0.01)
        })
    }

    /// `sweep` < 2π leaves a gap between the endpoints.
    private func circlePoints(center: CGPoint, radius: CGFloat,
                              sweep: CGFloat = 2 * CGFloat.pi,
                              steps: Int = 64) -> [CGPoint] {
        (0...steps).map { i in
            let angle = sweep * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: center.x + radius * cos(angle),
                           y: center.y + radius * sin(angle))
        }
    }

    func testClosedCircleBecomesPart() {
        let stroke = makeStroke(points: circlePoints(center: CGPoint(x: 100, y: 100), radius: 50))
        let parts = PartExtractor.parts(from: [stroke])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].sourceStrokeID, stroke.id)
        XCTAssertGreaterThanOrEqual(parts[0].contour.count, 3)
    }

    func testOpenLineIsNotAPart() {
        let stroke = makeStroke(points: (0...50).map { CGPoint(x: CGFloat($0) * 4, y: 100) })
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testNearlyClosedArcBecomesPart() {
        // 350° of an r=50 circle: gap ≈ 8.7, arc ≈ 305 → ratio ≈ 0.03 → closes
        let stroke = makeStroke(points: circlePoints(
            center: CGPoint(x: 100, y: 100), radius: 50,
            sweep: 2 * CGFloat.pi * 350 / 360))
        XCTAssertEqual(PartExtractor.parts(from: [stroke]).count, 1)
    }

    func testHalfCircleIsNotAPart() {
        // 180°: gap = 100 (the diameter), arc ≈ 157 → ratio ≈ 0.64 → open
        let stroke = makeStroke(points: circlePoints(
            center: CGPoint(x: 100, y: 100), radius: 50, sweep: CGFloat.pi))
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testZeroAreaScribbleIsNotAPart() {
        // Out and back along the same line: gap 0, but |signed area| ≈ 0
        var pts = (0...25).map { CGPoint(x: CGFloat($0) * 4, y: 100) }
        pts += (0...25).reversed().map { CGPoint(x: CGFloat($0) * 4, y: 100) }
        let stroke = makeStroke(points: pts)
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testTinyStrokeIsNotAPart() {
        let stroke = makeStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        XCTAssertTrue(PartExtractor.parts(from: [stroke]).isEmpty)
    }

    func testMixedStrokesOnlyClosedBecomeParts() {
        let closed = makeStroke(points: circlePoints(center: CGPoint(x: 100, y: 100), radius: 40))
        let open = makeStroke(points: (0...50).map { CGPoint(x: CGFloat($0) * 4, y: 300) })
        let parts = PartExtractor.parts(from: [closed, open])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].sourceStrokeID, closed.id)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/PartExtractorTests
```

Expected: **build failure** — `cannot find 'PartExtractor' in scope`. That is the failing state for a not-yet-created type; proceed.

- [ ] **Step 4: Write the implementation**

Create `PenSculpt/Drawing/PartExtractor.swift`:

```swift
import Foundation

/// A closed region extracted from a single stroke — one inflation part.
/// The contour is an implicitly closed polygon (last→first edge implied),
/// matching ShapeInflater.containsAndDistance's wrap-around convention.
struct Part: Equatable {
    var contour: [CGPoint]
    let sourceStrokeID: UUID
}

enum PartExtractor {

    /// Extracts closed-loop parts from an object's strokes. Open strokes
    /// never become parts — they stay as surface decoration ink.
    static func parts(from strokes: [Stroke], config: SculptConfig = .default) -> [Part] {
        strokes.compactMap { part(from: $0, config: config) }
    }

    private static func part(from stroke: Stroke, config: SculptConfig) -> Part? {
        let points = stroke.points.map(\.location)
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }

        var arcLength: CGFloat = 0
        for i in 1..<points.count {
            arcLength += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        guard arcLength > 0 else { return nil }

        let gap = hypot(last.x - first.x, last.y - first.y)
        guard gap <= config.partClosureRatio * arcLength else { return nil }

        guard abs(signedArea(points)) >= config.partMinArea else { return nil }

        return Part(contour: points, sourceStrokeID: stroke.id)
    }

    /// Shoelace formula over the implicitly closed loop.
    static func signedArea(_ loop: [CGPoint]) -> CGFloat {
        guard loop.count >= 3 else { return 0 }
        var area: CGFloat = 0
        var j = loop.count - 1
        for i in 0..<loop.count {
            area += loop[j].x * loop[i].y - loop[i].x * loop[j].y
            j = i
        }
        return area / 2
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/PartExtractorTests
```

Expected: `Test Suite 'PartExtractorTests' passed` — 7 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add PenSculpt/Drawing/PartExtractor.swift PenSculpt/Models/SculptConfig.swift \
        PenSculptTests/PartExtractorTests.swift PenSculpt.xcodeproj
git commit -m "feat(inference): PartExtractor detects closed-stroke parts"
```

---

### Task 2: Part loop cleanup — Laplacian smoothing + simplification

**Files:**
- Modify: `PenSculpt/Drawing/PartExtractor.swift` (from Task 1)
- Modify: `PenSculpt/Models/SculptConfig.swift`
- Test: `PenSculptTests/PartExtractorTests.swift` (append)

**Interfaces:**
- Consumes: `ContourExtractor.simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint]` (existing, internal, `PenSculpt/Drawing/ContourExtractor.swift:133`) and `config.contourMaxPoints` (existing).
- Produces: `PartExtractor.smoothed(_ loop: [CGPoint], passes: Int) -> [CGPoint]` (internal so tests can call it directly). `parts(from:config:)` signature unchanged; returned contours are now smoothed.

- [ ] **Step 1: Add config knob**

In `PenSculpt/Models/SculptConfig.swift`, after `partMinArea`:

```swift
    /// Wrap-around Laplacian smoothing passes applied to each part loop.
    var partSmoothingPasses: Int = 2
```

- [ ] **Step 2: Write the failing tests**

Append to `PenSculptTests/PartExtractorTests.swift` (inside the class):

```swift
    // MARK: - Loop cleanup (Task 2)

    func testSmoothingPreservesPointCount() {
        let loop = circlePoints(center: CGPoint(x: 100, y: 100), radius: 50)
        let smoothed = PartExtractor.smoothed(loop, passes: 2)
        XCTAssertEqual(smoothed.count, loop.count)
    }

    func testSmoothingReducesWobble() {
        // Alternating ±6 radial jitter: the 1-2-1 kernel cancels it almost exactly
        let center = CGPoint(x: 100, y: 100)
        let steps = 64
        let noisy = (0..<steps).map { i -> CGPoint in
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let r: CGFloat = 50 + (i % 2 == 0 ? 6 : -6)
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        func maxDeviation(_ pts: [CGPoint]) -> CGFloat {
            pts.map { abs(hypot($0.x - center.x, $0.y - center.y) - 50) }.max()!
        }
        let smoothed = PartExtractor.smoothed(noisy, passes: 2)
        XCTAssertLessThan(maxDeviation(smoothed), maxDeviation(noisy) / 2,
                          "Smoothing should at least halve alternating jitter")
    }

    func testSmoothedPartStillCloses() {
        // A noisy near-closed circle must survive extraction with smoothing on
        let center = CGPoint(x: 100, y: 100)
        let noisy = (0...80).map { i -> CGPoint in
            let angle = 2 * CGFloat.pi * 350 / 360 * CGFloat(i) / 80
            let r: CGFloat = 50 + (i % 2 == 0 ? 4 : -4)
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        XCTAssertEqual(PartExtractor.parts(from: [makeStroke(points: noisy)]).count, 1)
    }

    func testOversizedLoopGetsSimplified() {
        // 800-point circle exceeds contourMaxPoints (500) → Douglas–Peucker kicks in
        let loop = circlePoints(center: CGPoint(x: 300, y: 300), radius: 100, steps: 800)
        let parts = PartExtractor.parts(from: [makeStroke(points: loop)])
        XCTAssertEqual(parts.count, 1)
        XCTAssertLessThan(parts[0].contour.count, 500)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/PartExtractorTests
```

Expected: **build failure** — `type 'PartExtractor' has no member 'smoothed'`.

- [ ] **Step 4: Implement smoothing and wire it into extraction**

In `PenSculpt/Drawing/PartExtractor.swift`, add:

```swift
    /// Wrap-around 1-2-1 Laplacian smoothing over the closed loop. Kills ink
    /// wobble; the center weight limits the shrink of plain neighbor averaging.
    static func smoothed(_ loop: [CGPoint], passes: Int) -> [CGPoint] {
        guard passes > 0, loop.count >= 3 else { return loop }
        var pts = loop
        for _ in 0..<passes {
            let n = pts.count
            var next = pts
            for i in 0..<n {
                let prev = pts[(i + n - 1) % n]
                let succ = pts[(i + 1) % n]
                next[i] = CGPoint(x: (prev.x + 2 * pts[i].x + succ.x) / 4,
                                  y: (prev.y + 2 * pts[i].y + succ.y) / 4)
            }
            pts = next
        }
        return pts
    }
```

And replace the last two lines of `part(from:config:)` (the area guard and return) with:

```swift
        var contour = smoothed(points, passes: config.partSmoothingPasses)
        if contour.count > Int(config.contourMaxPoints) {
            contour = ContourExtractor.simplify(contour, tolerance: 1.0)
        }
        guard contour.count >= 3,
              abs(signedArea(contour)) >= config.partMinArea else { return nil }

        return Part(contour: contour, sourceStrokeID: stroke.id)
```

(The closure test stays on the raw points; area is now checked on the cleaned loop.)

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 3. Expected: `Test Suite 'PartExtractorTests' passed` — 11 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add PenSculpt/Drawing/PartExtractor.swift PenSculpt/Models/SculptConfig.swift \
        PenSculptTests/PartExtractorTests.swift
git commit -m "feat(inference): smooth and simplify part loops"
```

---

### Task 3: Multi-part inflation with smooth-max union

**Files:**
- Modify: `PenSculpt/Drawing/ShapeInflater.swift:19-79` (the `inflate` function; add one private helper)
- Modify: `PenSculpt/Models/SculptConfig.swift`
- Test: `PenSculptTests/MultiPartInflationTests.swift` (create)

**Interfaces:**
- Consumes: `PartExtractor.parts(from:config:) -> [Part]` (Task 1/2), existing `ContourExtractor.extract`, `containsAndDistance`, `buildMesh`, `subdivideElongatedEdges`.
- Produces: `ShapeInflater.inflate(strokes:config:) -> Mesh` — **signature unchanged**; adds `private static func smoothMax(_ a: Float, _ b: Float, k: Float) -> Float`. No other file sees a new API.

- [ ] **Step 1: Add config knob**

In `PenSculpt/Models/SculptConfig.swift`, after `partSmoothingPasses`:

```swift
    /// Smooth-max blend width (world pt) where inflated parts overlap.
    /// 0 degrades to a hard max (paper-cutout joints).
    var partBlendRadius: CGFloat = 10
```

- [ ] **Step 2: Write the failing tests**

Create `PenSculptTests/MultiPartInflationTests.swift`:

```swift
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
        XCTAssertEqual(with, without,
            "A shallow part inside a deep host must be absorbed, not cratered")
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
```

- [ ] **Step 3: Run tests to verify the new behavior fails**

```bash
xcodegen generate
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/MultiPartInflationTests
```

Expected: FAIL. `testPerPartDepthIndependence` fails on the `headDepth < 45` assertion (single global maxDist puffs the head to ≈55); `testOpenStrokeAddsNoVolume` fails (the chord ink perturbs the Vision contour). Fallback and validity tests may already pass — that is fine.

- [ ] **Step 4: Rewrite `ShapeInflater.inflate` with per-part fields and smooth-max union**

In `PenSculpt/Drawing/ShapeInflater.swift`, replace the whole `inflate` function (lines 19–79) with:

```swift
    /// Inflates 2D contours into a closed 3D mesh by using edge distance as
    /// depth. Closed strokes each become an independently inflated part with
    /// its own maxDist, united by a smooth max in the depth field; when no
    /// stroke closes, the whole drawing falls back to the single Vision
    /// contour (previous behavior).
    static func inflate(strokes: [Stroke], config: SculptConfig = .default) -> Mesh {
        let allPoints = strokes.flatMap { $0.points.map(\.location) }

        let parts = PartExtractor.parts(from: strokes, config: config)
        let contours: [[CGPoint]]
        if parts.isEmpty {
            let contour = ContourExtractor.extract(from: strokes, config: config)
            guard contour.count >= 3 else { return Mesh() }
            contours = [contour]
        } else {
            contours = parts.map(\.contour)
        }

        // Bounding box with padding — over ALL strokes, so decoration ink
        // stays inside the grid and originRect mapping is unchanged.
        let xs = allPoints.map(\.x), ys = allPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return Mesh() }

        // Adaptive grid spacing: cap grid to ~150 cells per axis to prevent freezing
        let shapeSize = max(maxX - minX, maxY - minY)
        let gridSpacing = max(config.gridSpacing, shapeSize / 150)
        let pad = gridSpacing * 2
        let x0 = minX - pad, y0 = minY - pad
        let x1 = maxX + pad, y1 = maxY + pad

        let cols = max(2, Int((x1 - x0) / gridSpacing))
        let rows = max(2, Int((y1 - y0) / gridSpacing))
        let cellCount = rows * cols

        // One distance field per part; each field parallelized per-row.
        // containsAndDistance merges point-in-polygon + nearest-edge in one loop.
        var distanceFields = [[Float]](repeating: [], count: contours.count)
        for (pi, contour) in contours.enumerated() {
            var field = [Float](repeating: 0, count: cellCount)
            field.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: rows) { row in
                    let rowOffset = row * cols
                    for col in 0..<cols {
                        let p = CGPoint(x: x0 + CGFloat(col) * gridSpacing,
                                        y: y0 + CGFloat(row) * gridSpacing)
                        let (inside, dist) = containsAndDistance(p, contour: contour)
                        if inside {
                            buffer[rowOffset + col] = Float(dist)
                        }
                    }
                }
            }
            distanceFields[pi] = field
        }

        // Per-part maxDist: a thin limb keeps a thin profile while a fat
        // torso puffs to its own scale.
        let maxDists = distanceFields.map { $0.max() ?? 0 }
        guard maxDists.contains(where: { $0 > 0 }) else { return Mesh() }

        // Spherical profile per part — depth = sqrt(d * (2*maxDist - d)) —
        // then unite parts with a smooth max so overlaps blend at joints.
        let blend = Float(config.partBlendRadius)
        var depths = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let cell = row * cols + col
                var combined: Float = 0
                var hasDepth = false
                for pi in 0..<distanceFields.count {
                    let d = distanceFields[pi][cell]
                    guard d > 0 else { continue }
                    let depth = sqrt(d * (2 * maxDists[pi] - d))
                    combined = hasDepth ? smoothMax(combined, depth, k: blend) : depth
                    hasDepth = true
                }
                depths[row][col] = combined
            }
        }

        // Build mesh: front face (z > 0) + back face (z < 0)
        var boundaryVertices = Set<UInt32>()
        let mesh = buildMesh(depths: depths, rows: rows, cols: cols,
                              x0: Float(x0), y0: Float(y0), spacing: Float(gridSpacing),
                              boundaryVertices: &boundaryVertices)
        return subdivideElongatedEdges(mesh, maxEdgeLength: Float(gridSpacing) * 4,
                                        boundaryVertices: boundaryVertices,
                                        passes: config.seamSubdivisionPasses)
    }

    /// Polynomial smooth maximum (the mirrored SDF smooth-min). k = 0 → hard max.
    private static func smoothMax(_ a: Float, _ b: Float, k: Float) -> Float {
        guard k > 0 else { return max(a, b) }
        let h = max(0, min(1, 0.5 + 0.5 * (b - a) / k))
        return a + (b - a) * h + k * h * (1 - h)
    }
```

Everything below `// MARK: - Combined containment + distance` stays exactly as it is.

- [ ] **Step 5: Run the new tests**

Same command as Step 3. Expected: `Test Suite 'MultiPartInflationTests' passed` — 6 tests, 0 failures.

- [ ] **Step 6: Run the full pipeline regression suite**

```bash
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/InferencePipelineTests \
  -only-testing:PenSculptTests/PipelineDiagnosticTests \
  -only-testing:PenSculptTests/PipelineVisualTests \
  -only-testing:PenSculptTests/MeshTests \
  -only-testing:PenSculptTests/StrokeLifterTests \
  -only-testing:PenSculptTests/PartExtractorTests
```

Expected: all suites pass. `StrokeLifterTests` is included because it already pins the spec's "decoration ink far outside the volume is dropped" behavior (`testLiftDropsPointsOffTheMesh`, `testLiftToleranceStillDropsClearMisses`, `testLiftReportsFullyMissingStrokeAsUnlifted`) — no new lift test is needed. Watch specifically: `PipelineVisualTests.testCircleDepthRatio` and `testVisualizeCircle`/`testVisualizeOval` — these draw single closed strokes that now take the **part path** (polyline contour, smoothed) instead of Vision. Extents shift slightly; assertions are ratio-based and must still pass. If a diagnostic assertion fails on a marginal ratio, inspect the printed extents before touching thresholds — a big change means a real bug (e.g. per-part maxDist computed over the wrong buffer).

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Drawing/ShapeInflater.swift PenSculpt/Models/SculptConfig.swift \
        PenSculptTests/MultiPartInflationTests.swift PenSculpt.xcodeproj
git commit -m "feat(inference): per-part inflation united by smooth-max depth blending"
```

---

### Task 4: Visual fixture, full regression, docs

**Files:**
- Modify: `PenSculptTests/PipelineVisualTests.swift` (add fixture after the `handDrawnVaseStrokes` section, ~line 220)
- Modify: `TODO.md` (Inference Pipeline section, ~line 45)

**Interfaces:**
- Consumes: `ShapeInflater.sculpt` via the existing `runDiagnostic(name:strokes:)` helper (`PipelineVisualTests.swift:263`). Produces nothing consumed later.

- [ ] **Step 1: Add the multi-part figure fixture**

In `PenSculptTests/PipelineVisualTests.swift`, after the `testVisualizeHandDrawnVase` function:

```swift
    // MARK: - Multi-part figure (closed-stroke person: head/body/arms/legs)

    private var figureStrokes: [Stroke] {
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                     steps: Int = 48) -> Stroke {
            var points: [StrokePoint] = []
            for i in 0...steps {
                let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
                points.append(StrokePoint(
                    location: CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle)),
                    pressure: 1, tilt: 0, azimuth: 0, timestamp: CGFloat(i) * 0.01))
            }
            return Stroke(points: points)
        }
        return [
            ellipse(cx: 300, cy: 200, rx: 60, ry: 60),    // head
            ellipse(cx: 300, cy: 400, rx: 90, ry: 150),   // body (overlaps head at y≈250)
            ellipse(cx: 195, cy: 380, rx: 25, ry: 90),    // left arm
            ellipse(cx: 405, cy: 380, rx: 25, ry: 90),    // right arm
            ellipse(cx: 260, cy: 610, rx: 30, ry: 80),    // left leg
            ellipse(cx: 340, cy: 610, rx: 30, ry: 80),    // right leg
        ]
    }

    func testVisualizeFigure() {
        runDiagnostic(name: "figure", strokes: figureStrokes)
    }
```

- [ ] **Step 2: Run the visual test and inspect the output**

```bash
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/PipelineVisualTests/testVisualizeFigure
```

Expected: PASS, with `📸 …/PenSculptDiag/figure_pipeline.png` and `figure_mesh_profile.png` printed. Open both images: the profile must show distinct head/body/limb bulges (compound volumes), not one uniform pillow.

- [ ] **Step 3: Run the entire test suite**

```bash
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

Expected: all suites pass, 0 failures.

- [ ] **Step 4: Update TODO.md**

In `TODO.md`, under `### Inference Pipeline` after the `ShapeInflater` line, add:

```markdown
- [x] PartExtractor + multi-part inflation (closed strokes → per-part depth, smooth-max union) — O[ ] S[ ]
```

- [ ] **Step 5: Commit**

```bash
git add PenSculptTests/PipelineVisualTests.swift TODO.md
git commit -m "test(inference): multi-part figure visual fixture; update TODO"
```
