# Inflation Mode Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Sculpt toolbar toggle that switches the active object's inflation profile between organic (current spherical) and straight (cookie-cutter cube), re-inferring on tap, with per-object persistence in the `.pensculpt` document.

**Architecture:** Add an `InflationMode` enum and a stored `inflationMode` property on `SculptObject` (default `.organic`, decodable with fallback for backwards-compat). Extend `ShapeInflater.inflate` with an `inflationMode` parameter that branches the depth profile: `sqrt(d*(2*maxDist-d))` for organic, constant `maxDist` for straight. `SculptScreen` adds a toolbar button that toggles the active object's mode and calls `reInfer()`, which reads the mode off the object and threads it through the pipeline.

**Tech Stack:** Swift, SwiftUI, Codable/JSON document storage, XCTest.

**Spec:** [`docs/superpowers/specs/2026-05-25-inflation-mode-design.md`](../specs/2026-05-25-inflation-mode-design.md)

---

## File Structure

- **Modify:** `PenSculpt/Models/SculptObject.swift`
  - Add `InflationMode` enum (top-level, in this file)
  - Add `var inflationMode: InflationMode = .organic` to `SculptObject`
  - Update `init(...)` to accept inflationMode
  - Update `init(from decoder:)` with backwards-compat fallback
  - Update `CodingKeys` to include `inflationMode`

- **Modify:** `PenSculpt/Drawing/ShapeInflater.swift`
  - Add `inflationMode:` parameter to `inflate(strokes:config:)`
  - Add `inflationMode:` parameter to `sculpt(from:config:)`
  - `sculpt` sets the returned `SculptObject.inflationMode`
  - Branch the depth-conversion loop on the mode

- **Modify:** `PenSculpt/Views/SculptScreen.swift`
  - Add `inflationMode` reads inside `reInfer`, `autoReInfer`, `reInferMorph`
  - `inferNewObject` defaults to `.organic`
  - Add a new toolbar button in `topToolbar` (extracted in commit `56b22ac`)

- **Modify:** `PenSculpt/Views/Tooltips/TooltipID.swift`
  - Add `sculptInflationMode` case + title/subtitle

- **Create:** `PenSculptTests/ShapeInflaterInflationModeTests.swift`
  - Tests for the depth-profile branch in both modes

- **Create:** `PenSculptTests/SculptObjectInflationModeTests.swift`
  - Backwards-compat decode test

The existing `SculptScreen.swift` is large but the topToolbar var (extracted earlier) is the only place to touch.

---

## Task 1: InflationMode Enum + SculptObject Property

**Files:**
- Modify: `PenSculpt/Models/SculptObject.swift`
- Create: `PenSculptTests/SculptObjectInflationModeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create file `PenSculptTests/SculptObjectInflationModeTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class SculptObjectInflationModeTests: XCTestCase {

    func testDefaultInflationModeIsOrganic() {
        let obj = SculptObject(mesh: Mesh(), sourceStrokeIDs: [])
        XCTAssertEqual(obj.inflationMode, .organic)
    }

    func testInitWithExplicitStraightMode() {
        let obj = SculptObject(mesh: Mesh(), sourceStrokeIDs: [], inflationMode: .straight)
        XCTAssertEqual(obj.inflationMode, .straight)
    }

    func testRoundTripPreservesInflationMode() throws {
        let original = SculptObject(mesh: Mesh(), sourceStrokeIDs: [], inflationMode: .straight)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SculptObject.self, from: data)
        XCTAssertEqual(decoded.inflationMode, .straight)
    }

    func testDecodeWithoutInflationModeFieldFallsBackToOrganic() throws {
        // Simulates a .pensculpt file from before this feature shipped.
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "mesh": {"vertices":[],"indices":[]},
            "sourceStrokeIDs": [],
            "surfaceStrokes": [],
            "originRect": [[0,0],[0,0]]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SculptObject.self, from: legacyJSON)
        XCTAssertEqual(decoded.inflationMode, .organic,
                       "missing inflationMode should default to .organic for backwards-compat")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/SculptObjectInflationModeTests 2>&1 | grep -E "passed|failed|error"
```

Expected: compile errors (no `InflationMode` type, no `inflationMode` property on `SculptObject`).

- [ ] **Step 3: Add `InflationMode` enum at the top of SculptObject.swift**

Open `PenSculpt/Models/SculptObject.swift`. Below the existing `import simd` line and above `struct SurfaceStroke`, insert:

```swift
enum InflationMode: String, Codable, Equatable, Sendable {
    case organic
    case straight
}
```

- [ ] **Step 4: Add `inflationMode` property to SculptObject**

In `PenSculpt/Models/SculptObject.swift`, find `struct SculptObject` (around line 109) and:

1. Add the stored property right after `originRect`:
```swift
var inflationMode: InflationMode = .organic
```

2. Update the memberwise init to accept it:
```swift
init(id: UUID = UUID(), mesh: Mesh, sourceStrokeIDs: Set<UUID>,
     surfaceStrokes: [SurfaceStroke] = [], originRect: CGRect = .zero,
     inflationMode: InflationMode = .organic) {
    self.id = id
    self.mesh = mesh
    self.sourceStrokeIDs = sourceStrokeIDs
    self.surfaceStrokes = surfaceStrokes
    self.originRect = originRect
    self.inflationMode = inflationMode
}
```

3. Update `init(from decoder:)` to decode with backwards-compat fallback:
```swift
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    mesh = try container.decode(Mesh.self, forKey: .mesh)
    sourceStrokeIDs = try container.decode(Set<UUID>.self, forKey: .sourceStrokeIDs)
    surfaceStrokes = try container.decodeIfPresent([SurfaceStroke].self, forKey: .surfaceStrokes) ?? []
    originRect = try container.decodeIfPresent(CGRect.self, forKey: .originRect) ?? .zero
    inflationMode = try container.decodeIfPresent(InflationMode.self, forKey: .inflationMode) ?? .organic
}
```

4. If there's an explicit `CodingKeys` enum, add `case inflationMode`. (Check the file — if SculptObject relies on auto-synthesized CodingKeys, this is unnecessary.)

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/SculptObjectInflationModeTests 2>&1 | grep -E "passed|failed|error"
```

Expected: 4 tests pass.

- [ ] **Step 6: Run full test suite to confirm no regression**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' 2>&1 | grep -E "Test Suite '|failed" | tail -10
```

Expected: previously-passing suites still pass. `MeshBVHTests` may still fail (pre-existing).

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Models/SculptObject.swift PenSculptTests/SculptObjectInflationModeTests.swift
git commit -m "$(cat <<'EOF'
feat(inflation): add InflationMode enum and SculptObject.inflationMode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: ShapeInflater Branch on InflationMode

**Files:**
- Modify: `PenSculpt/Drawing/ShapeInflater.swift`
- Create: `PenSculptTests/ShapeInflaterInflationModeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create file `PenSculptTests/ShapeInflaterInflationModeTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class ShapeInflaterInflationModeTests: XCTestCase {

    /// Builds a stroke shaped like a square so tests have a deterministic contour.
    private func makeSquareStroke(size: CGFloat = 100) -> Stroke {
        let pts: [StrokePoint] = [
            StrokePoint(location: CGPoint(x: 0, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: size, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: size, y: size), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: 0, y: size), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: 0, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ]
        return Stroke(points: pts)
    }

    func testInflateDefaultModeIsOrganic() {
        // Calling inflate without specifying mode produces the same mesh as organic.
        let stroke = makeSquareStroke()
        let defaultMesh = ShapeInflater.inflate(strokes: [stroke])
        let organicMesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .organic)
        XCTAssertEqual(defaultMesh.vertices.count, organicMesh.vertices.count)
        XCTAssertEqual(defaultMesh.indices, organicMesh.indices)
    }

    func testOrganicProducesDomedMesh() {
        // Organic profile: depth varies across the interior — vertices near the center
        // are taller than vertices near the edge.
        let stroke = makeSquareStroke()
        let mesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .organic)
        let frontFaceZs = mesh.vertices.map { $0.position.z }.filter { $0 > 0 }
        guard let minZ = frontFaceZs.min(), let maxZ = frontFaceZs.max() else {
            return XCTFail("Expected at least one front-face vertex")
        }
        XCTAssertGreaterThan(maxZ - minZ, 0.5,
                             "organic mode should produce varying depth (dome), not a flat slab")
    }

    func testStraightProducesFlatTopMesh() {
        // Straight profile: all front-face vertices have approximately the same z
        // (a flat plateau), modulo the edge transition.
        let stroke = makeSquareStroke()
        let mesh = ShapeInflater.inflate(strokes: [stroke], inflationMode: .straight)
        let frontFaceZs = mesh.vertices.map { $0.position.z }.filter { $0 > 0 }
        guard let minZ = frontFaceZs.min(), let maxZ = frontFaceZs.max(),
              minZ > 0 else {
            return XCTFail("Expected positive front-face vertices")
        }
        XCTAssertEqual(maxZ, minZ, accuracy: 0.01,
                       "straight mode should produce a flat top: every interior vertex has the same z")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/ShapeInflaterInflationModeTests 2>&1 | grep -E "passed|failed|error"
```

Expected: compile error on `inflationMode:` parameter (doesn't exist yet) or test failures because `inflate` doesn't branch.

- [ ] **Step 3: Add inflationMode parameter to inflate()**

Open `PenSculpt/Drawing/ShapeInflater.swift`. Modify the signature of `inflate(strokes:config:)` (around line 20):

```swift
static func inflate(strokes: [Stroke], config: SculptConfig = .default, inflationMode: InflationMode = .organic) -> Mesh {
```

- [ ] **Step 4: Branch the depth conversion loop**

In `PenSculpt/Drawing/ShapeInflater.swift`, find the block that converts distance to depth (around lines 59-69):

Replace this:

```swift
        // Convert distance to depth using a sphere-like profile:
        // depth = sqrt(d * (2*maxDist - d)) gives a semicircular cross-section.
        var depths = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let d = depthBuffer[row * cols + col]
                if d > 0 {
                    depths[row][col] = sqrt(d * (2 * maxDist - d))
                }
            }
        }
```

With this:

```swift
        // Convert distance to depth using the chosen profile.
        // - organic: sqrt(d*(2*maxDist - d)) is a semicircular cross-section (dome).
        // - straight: constant maxDist inside the contour, zero outside (cookie-cutter).
        var depths = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let d = depthBuffer[row * cols + col]
                if d > 0 {
                    switch inflationMode {
                    case .organic:
                        depths[row][col] = sqrt(d * (2 * maxDist - d))
                    case .straight:
                        depths[row][col] = maxDist
                    }
                }
            }
        }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/ShapeInflaterInflationModeTests 2>&1 | grep -E "passed|failed|error"
```

Expected: 3 tests pass.

- [ ] **Step 6: Run full test suite to confirm no regression**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' 2>&1 | grep -E "Test Suite '|failed" | tail -10
```

Expected: previously-passing suites still pass. Pre-existing `MeshBVHTests` failures continue (unrelated).

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Drawing/ShapeInflater.swift PenSculptTests/ShapeInflaterInflationModeTests.swift
git commit -m "$(cat <<'EOF'
feat(inflation): branch ShapeInflater depth profile on inflationMode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Thread inflationMode Through sculpt() and SculptScreen Infer Paths

**Files:**
- Modify: `PenSculpt/Drawing/ShapeInflater.swift`
- Modify: `PenSculpt/Views/SculptScreen.swift`

- [ ] **Step 1: Add inflationMode parameter to sculpt()**

In `PenSculpt/Drawing/ShapeInflater.swift`, modify `sculpt(from:config:)` (around line 7):

Replace:

```swift
    static func sculpt(from strokes: [Stroke], config: SculptConfig = .default) -> SculptObject {
        let mesh = inflate(strokes: strokes, config: config)
        let allPoints = strokes.flatMap { $0.points.map(\.location) }
        let xs = allPoints.map(\.x), ys = allPoints.map(\.y)
        let originRect = CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
        return SculptObject(mesh: mesh, sourceStrokeIDs: Set(strokes.map(\.id)), originRect: originRect)
    }
```

With:

```swift
    static func sculpt(from strokes: [Stroke], config: SculptConfig = .default, inflationMode: InflationMode = .organic) -> SculptObject {
        let mesh = inflate(strokes: strokes, config: config, inflationMode: inflationMode)
        let allPoints = strokes.flatMap { $0.points.map(\.location) }
        let xs = allPoints.map(\.x), ys = allPoints.map(\.y)
        let originRect = CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
        return SculptObject(mesh: mesh, sourceStrokeIDs: Set(strokes.map(\.id)),
                            originRect: originRect, inflationMode: inflationMode)
    }
```

- [ ] **Step 2: Update SculptScreen.reInfer to read & pass inflationMode**

In `PenSculpt/Views/SculptScreen.swift`, find `private func reInfer()` (around line 420). Replace:

```swift
    private func reInfer() {
        guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
        let id = sculptObjects[activeObjectIndex].id
        let oldStrokes = sculptObjects[activeObjectIndex].surfaceStrokes
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
```

With:

```swift
    private func reInfer() {
        guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
        let id = sculptObjects[activeObjectIndex].id
        let oldStrokes = sculptObjects[activeObjectIndex].surfaceStrokes
        let mode = sculptObjects[activeObjectIndex].inflationMode
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg, inflationMode: mode)
```

- [ ] **Step 3: Update SculptScreen.reInferMorph similarly**

In `PenSculpt/Views/SculptScreen.swift`, find `private func reInferMorph()` (around line 445). Replace:

```swift
    private func reInferMorph() {
        guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
        let id = sculptObjects[activeObjectIndex].id
        let oldStrokes = sculptObjects[activeObjectIndex].surfaceStrokes
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
```

With:

```swift
    private func reInferMorph() {
        guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
        let id = sculptObjects[activeObjectIndex].id
        let oldStrokes = sculptObjects[activeObjectIndex].surfaceStrokes
        let mode = sculptObjects[activeObjectIndex].inflationMode
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg, inflationMode: mode)
```

- [ ] **Step 4: Update SculptScreen.autoReInfer similarly**

In `PenSculpt/Views/SculptScreen.swift`, find `private func autoReInfer(objectID:newStrokeIDs:)` (around line 396). Replace:

```swift
    private func autoReInfer(objectID: UUID, newStrokeIDs: Set<UUID>) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        let oldStrokes = sculptObjects[idx].surfaceStrokes
        isReInferring = true
        let sourceStrokes = strokes
        let cfg = config
        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
```

With:

```swift
    private func autoReInfer(objectID: UUID, newStrokeIDs: Set<UUID>) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        let oldStrokes = sculptObjects[idx].surfaceStrokes
        let mode = sculptObjects[idx].inflationMode
        isReInferring = true
        let sourceStrokes = strokes
        let cfg = config
        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg, inflationMode: mode)
```

- [ ] **Step 5: inferNewObject keeps default (.organic) — no change needed**

`inferNewObject` calls `ShapeInflater.sculpt(from: sourceStrokes, config: cfg)`. The new default `inflationMode: .organic` is correct for new objects. **No change required.** Verify by reading the function (around line 380) and confirming it doesn't override.

- [ ] **Step 6: Run full test suite**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' 2>&1 | grep -E "Test Suite '|failed" | tail -10
```

Expected: all previously-passing suites still pass.

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Drawing/ShapeInflater.swift PenSculpt/Views/SculptScreen.swift
git commit -m "$(cat <<'EOF'
feat(inflation): thread inflationMode through sculpt() and re-infer paths

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: UI Toggle Button + Tooltip

**Files:**
- Modify: `PenSculpt/Views/SculptScreen.swift`
- Modify: `PenSculpt/Views/Tooltips/TooltipID.swift`

- [ ] **Step 1: Add the tooltip case**

In `PenSculpt/Views/Tooltips/TooltipID.swift`, find the section with sculpt-related cases (around line 30-45). Add a new case. The existing top-toolbar cases include `sculptClose`, `sculptReinfer`, `sculptReinferMorph`, `sculptAutoProject`, `sculptExport`. Add `sculptInflationMode` next to them:

```swift
    case sculptReinferMorph
    case sculptInflationMode
    case sculptAutoProject
```

Then add the content case in the switch statement (where the existing cases return `.init(title:subtitle:)`):

```swift
        case .sculptInflationMode: return .init(title: "Inflation", subtitle: "Switch between organic (curved) and straight (cube) shape")
```

Place it in the same order: between `sculptReinferMorph` and `sculptAutoProject`.

- [ ] **Step 2: Add the toggle button in SculptScreen.topToolbar**

In `PenSculpt/Views/SculptScreen.swift`, find the `private var topToolbar: some View` (extracted in commit `56b22ac`). Inside the `HStack(spacing: 12) { ... }`, after the `Button(action: reInferMorph)` block (the sparkles button) and before the `Button { autoProjectStrokes.toggle() }` (the auto-project button), insert:

```swift
            Button {
                guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
                let current = sculptObjects[activeObjectIndex].inflationMode
                let newMode: InflationMode = (current == .organic) ? .straight : .organic
                sculptObjects[activeObjectIndex].inflationMode = newMode
                reInfer()
            } label: {
                let isStraight = activeObjectIndex < sculptObjects.count
                    && sculptObjects[activeObjectIndex].inflationMode == .straight
                Image(systemName: isStraight ? "cube.fill" : "circle")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isStraight ? .blue : .secondary)
            }
            .disabled(isReInferring)
            .tooltip(.sculptInflationMode)
```

- [ ] **Step 3: Build to verify compile**

```bash
xcodebuild -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | grep -E "error:|BUILD" | head -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add PenSculpt/Views/SculptScreen.swift PenSculpt/Views/Tooltips/TooltipID.swift
git commit -m "$(cat <<'EOF'
feat(inflation): add organic/straight toggle button to Sculpt toolbar

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Manual Verification on iPad

**Files:** none (verification only)

- [ ] **Step 1: Build and run on iPad**

Build the app to the iPad (or simulator if iPad isn't available).

- [ ] **Step 2: Run the manual checklist**

- [ ] Draw a square on the 2D canvas → enter Sculpt → confirm it inflates as the **organic dome** (current behavior)
- [ ] In Sculpt, find the new toolbar button between sparkles and auto-project — icon is `circle` (gray) when organic
- [ ] Tap the button → spinner appears (~30s on iPad) → confirms it becomes a **flat-top cube** with vertical sides
- [ ] Icon now shows `cube.fill` (blue) — visual state matches
- [ ] Tap again → spinner → back to organic dome; icon back to `circle` (gray)
- [ ] **Surface strokes preserved:** in organic mode, paint a few surface strokes; toggle to straight; confirm strokes reproject onto the cube (might look weird but should be there)
- [ ] **Multi-object independence:** if you can create 2 objects in the scene, set one to straight and the other to organic; switch between them with whatever object-cycling exists; confirm each keeps its mode
- [ ] **Persistence:** save (auto-save / close + reopen the document) → reopen → confirm the cube stays a cube and the organic dome stays a dome
- [ ] **Tooltip:** hover Pencil over the button → tooltip shows "Inflation · Switch between organic (curved) and straight (cube) shape"
- [ ] Toggle disabled while `isReInferring` (just like other infer buttons) — try double-tapping fast, confirm it doesn't double-trigger

- [ ] **Step 3: Accumulate any bugs (don't fix piecemeal)**

Per the project's batch-fix workflow, write down observations and apply fixes in one go after the full pass.

- [ ] **Step 4: If issues found, apply fixes in a single commit**

```bash
git add PenSculpt/...
git commit -m "fix(inflation): address manual test findings"
```

- [ ] **Step 5: Push to both remotes**

```bash
git push origin alexandre
git push upstream alexandre
```

- [ ] **Step 6: Update TODO.md and memory**

In `TODO.md` (no specific line — add a Future Stages or Stage 2 line as appropriate, e.g. under "Future Stages" or wherever feature roadmap is tracked):

If a line exists for inflation mode, mark `[x]`. If not, the spec/plan combo already documents the feature — no new TODO entry needed unless one was created earlier.

Update memory: replace the backlog entry `inflation_mode_toggle.md` to mark feature as shipped, including the date and the commit range.

Final commit + push of any doc/memory updates:

```bash
git add TODO.md
git commit -m "$(cat <<'EOF'
docs: mark inflation mode toggle as shipped

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin alexandre
git push upstream alexandre
```
