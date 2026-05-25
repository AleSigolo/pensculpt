# Perspective Camera Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single Sculpt toolbar button that toggles the renderer between orthographic and perspective cameras, with a long-press FOV slider, animated transition, and opt-in (resets on Sculpt re-entry).

**Architecture:** Add `ProjectionMode` enum + `perspectiveProjection` static func to `SculptRenderer`. The renderer holds an internal `projectionTransition: Float` (0 = ortho, 1 = perspective) and drives its own animation via `CACurrentMediaTime` (same pattern as the existing `updateMorph`). `combinedProjection` linearly interpolates between the two projection matrices using `projectionTransition`. The UI in `SculptScreen` calls a renderer method to request a target mode; renderer animates internally. FOV slider mutates `perspectiveFOV` live on the renderer.

**Tech Stack:** Swift, MetalKit (MTKView/MTKViewDelegate), SwiftUI, simd, XCTest.

**Spec:** [`docs/superpowers/specs/2026-05-25-perspective-camera-toggle-design.md`](../specs/2026-05-25-perspective-camera-toggle-design.md)

---

## File Structure

- **Modify:** `PenSculpt/Rendering/SculptRenderer.swift`
  - Add nested `ProjectionMode` enum
  - Add `perspectiveProjection(fovRadians:aspect:near:far:)` static func
  - Add `var projectionMode`, `var perspectiveFOV`, `var projectionTransition`, `private var transitionAnim` state
  - Modify `combinedProjection(viewSize:)` to interpolate
  - Add `setProjectionMode(_:animated:)` public method
  - Modify `draw(in:)` to call new `updateProjectionTransition()` helper

- **Modify:** `PenSculpt/Views/SculptScreen.swift`
  - Add `@State projectionMode`, `@State perspectiveFOV`, `@State showFOVPopover`
  - Add new toolbar button between `rotate.3d` and the eraser/deform area
  - Wire tap + long-press gestures; popover with `Slider`

- **Create:** `PenSculptTests/SculptRendererProjectionTests.swift`
  - Tests for the new static `perspectiveProjection` and the interpolation behavior of `combinedProjection`

The renderer file is large but the changes are localized (one enum, one func, a few props, two new methods). Don't restructure it.

---

## Task 1: ProjectionMode Enum + perspectiveProjection Static Func

**Files:**
- Modify: `PenSculpt/Rendering/SculptRenderer.swift`
- Create: `PenSculptTests/SculptRendererProjectionTests.swift`

- [ ] **Step 1: Write the failing test**

Create file `PenSculptTests/SculptRendererProjectionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/SculptRendererProjectionTests 2>&1 | grep -E "passed|failed|error"
```

Expected: compile error or "Cannot find 'perspectiveProjection' on type 'SculptRenderer'"

- [ ] **Step 3: Add ProjectionMode enum + perspectiveProjection static func**

In `PenSculpt/Rendering/SculptRenderer.swift`, find the existing `static func orthographicProjection(...)` (around line 720) and add right above it:

```swift
enum ProjectionMode {
    case orthographic
    case perspective
}

static func perspectiveProjection(fovRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let f = 1 / tan(fovRadians / 2)
    let zRange = far - near
    // Metal NDC: z in [0, 1], camera looks down -Z, right-handed.
    return simd_float4x4(
        SIMD4<Float>(f / aspect, 0, 0, 0),
        SIMD4<Float>(0, f, 0, 0),
        SIMD4<Float>(0, 0, -far / zRange, -1),
        SIMD4<Float>(0, 0, -(far * near) / zRange, 0)
    )
}
```

(Place the `enum ProjectionMode` declaration as a nested type inside `SculptRenderer`, near the other type declarations at the top of the class.)

- [ ] **Step 4: Run tests to verify they pass**

Run the same test command from Step 2.
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Rendering/SculptRenderer.swift PenSculptTests/SculptRendererProjectionTests.swift
git commit -m "$(cat <<'EOF'
feat(perspective): add ProjectionMode enum and perspectiveProjection matrix

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Interpolated combinedProjection

**Files:**
- Modify: `PenSculpt/Rendering/SculptRenderer.swift:241-251` (combinedProjection)
- Modify: `PenSculptTests/SculptRendererProjectionTests.swift` (add tests)

- [ ] **Step 1: Add failing tests for interpolation**

Append to `PenSculptTests/SculptRendererProjectionTests.swift` (inside the existing class):

```swift
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
```

Also add a test helper file or extension that exposes the test-only entry points:

```swift
// At the bottom of SculptRendererProjectionTests.swift, before the closing brace:
}

// MARK: - Test helpers (mirror of internals to keep tests self-contained)

extension SculptRenderer {
    static func makeForTesting() -> SculptRenderer {
        let device = MTLCreateSystemDefaultDevice()!
        return SculptRenderer(device: device)
    }

    func setCombinedBoundsForTesting(center: SIMD3<Float>, radius: Float) {
        self.combinedCenter = center
        self.combinedRadius = radius
        // Lock rotation to identity so tests have a deterministic view matrix.
        self.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    }
}
```

If `SculptRenderer.init(device:)` doesn't already exist with that signature, check the existing initializer and adapt the helper.

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/SculptRendererProjectionTests 2>&1 | grep -E "passed|failed|error"
```

Expected: the new tests fail (compile error on `projectionTransition`, `perspectiveFOV`, or `combinedCenter`/`combinedRadius` if private).

- [ ] **Step 3: Add state properties to SculptRenderer**

In `PenSculpt/Rendering/SculptRenderer.swift`, near the other instance properties (around line 45-80, where `rotation`, `combinedCenter`, `combinedRadius` live), add:

```swift
var projectionMode: ProjectionMode = .orthographic
var perspectiveFOV: Float = .pi / 180 * 50  // 50° default
/// 0 = pure ortho, 1 = pure perspective. Animated by updateProjectionTransition().
var projectionTransition: Float = 0
```

If `combinedCenter` and `combinedRadius` are declared `private`, change to internal (`var`) so the test helper can set them. If they were already internal, leave alone.

- [ ] **Step 4: Modify combinedProjection to interpolate**

Replace the existing `combinedProjection(viewSize:)` (around lines 241-251) with:

```swift
private func combinedProjection(viewSize: CGSize) -> simd_float4x4 {
    let r = combinedRadius
    let aspect = Float(viewSize.width) / Float(viewSize.height)

    let mOrtho = Self.orthographicProjection(
        left: -r * aspect, right: r * aspect,
        bottom: -r, top: r,
        near: -r * 10, far: r * 10
    )

    // For perspective, position the camera at a distance that preserves the
    // framing: an object of radius r should fill the same vertical fraction
    // as in ortho. Distance d satisfies r / d = tan(fov/2), so d = r / tan(fov/2).
    let cameraDistance = r / tan(perspectiveFOV / 2)
    let mPersp = Self.perspectiveProjection(
        fovRadians: perspectiveFOV,
        aspect: aspect,
        near: max(cameraDistance - r * 10, 0.01),
        far: cameraDistance + r * 10
    )
    // Perspective view matrix needs the extra camera-distance translation
    // along -Z (camera looks down -Z), composed with rotation about origin
    // and translation of object center to origin.
    let viewOrtho = simd_float4x4(rotation) * translationMatrix(-combinedCenter.x, -combinedCenter.y, -combinedCenter.z)
    let viewPersp = translationMatrix(0, 0, -cameraDistance) * viewOrtho

    let mvpOrtho = mOrtho * viewOrtho
    let mvpPersp = mPersp * viewPersp

    // Component-wise lerp. Linear is good enough for a 0.3s tween between
    // visually similar framings.
    let t = projectionTransition
    var result = simd_float4x4()
    for col in 0..<4 {
        result[col] = mvpOrtho[col] * (1 - t) + mvpPersp[col] * t
    }
    return result
}
```

- [ ] **Step 5: Make combinedCenter, combinedRadius, rotation accessible to tests**

Check the existing declarations (lines ~45-80). If they're `private`, change to internal (drop `private`). Add a comment if needed: `// Internal for test access via extension`.

- [ ] **Step 6: Run all tests to confirm no regression**

```bash
xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' 2>&1 | grep -E "Test Suite '|failed" | tail -20
```

Expected: All previously-passing test suites still pass. New `SculptRendererProjectionTests` passes. (Pre-existing failures in `MeshBVHTests` continue to fail — they're unrelated.)

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Rendering/SculptRenderer.swift PenSculptTests/SculptRendererProjectionTests.swift
git commit -m "$(cat <<'EOF'
feat(perspective): interpolated combinedProjection between ortho and persp

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Self-Driven Transition Animation in Renderer

**Files:**
- Modify: `PenSculpt/Rendering/SculptRenderer.swift` (add transition state struct + method)

- [ ] **Step 1: Add transition animation state struct**

In `PenSculpt/Rendering/SculptRenderer.swift`, near the existing `MorphState` struct (search for `struct MorphState`), add:

```swift
private struct TransitionState {
    let startTime: CFTimeInterval
    let fromTransition: Float
    let toTransition: Float
    let duration: CFTimeInterval
}
```

Then add an instance property near `activeMorph`:

```swift
private var activeTransition: TransitionState?
```

- [ ] **Step 2: Add public setProjectionMode method**

Add this method to `SculptRenderer` (place near other public state mutators, or near `setProjectionMode`-adjacent code):

```swift
func setProjectionMode(_ mode: ProjectionMode, animated: Bool) {
    let target: Float = (mode == .perspective) ? 1.0 : 0.0
    projectionMode = mode
    if animated {
        activeTransition = TransitionState(
            startTime: CACurrentMediaTime(),
            fromTransition: projectionTransition,
            toTransition: target,
            duration: 0.3
        )
    } else {
        activeTransition = nil
        projectionTransition = target
    }
}
```

- [ ] **Step 3: Add updateProjectionTransition helper**

Add right below `updateMorph()`:

```swift
private func updateProjectionTransition() {
    guard let trans = activeTransition else { return }
    let elapsed = CACurrentMediaTime() - trans.startTime
    let t = Float(min(elapsed / trans.duration, 1.0))
    // Same smoothstep used by morph for visual consistency.
    let smooth = t * t * (3 - 2 * t)
    projectionTransition = trans.fromTransition + (trans.toTransition - trans.fromTransition) * smooth
    if t >= 1.0 {
        projectionTransition = trans.toTransition
        activeTransition = nil
    }
}
```

- [ ] **Step 4: Hook updateProjectionTransition into draw(in:)**

In `draw(in view: MTKView)` (around line 164), modify the first line:

From:
```swift
if activeMorph != nil { updateMorph() }
```

To:
```swift
if activeMorph != nil { updateMorph() }
if activeTransition != nil { updateProjectionTransition() }
```

- [ ] **Step 5: Verify MTKView keeps redrawing during animation**

Check that the `MTKView` hosting this renderer has `isPaused = false` and `enableSetNeedsDisplay = false` (continuous redraw). If it's set up for on-demand redraw, the animation won't progress.

Search for the `MTKView` setup in the codebase:

```bash
grep -rn "isPaused\|enableSetNeedsDisplay\|preferredFramesPerSecond" /Users/alexandre/documents_copy/code/pensculpt/PenSculpt --include="*.swift"
```

If the view is on-demand only, add `view.setNeedsDisplay()` calls in `setProjectionMode` and `updateProjectionTransition` (call it on a stored weak reference to the MTKView), OR set the view to continuous redraw during the animation.

If the renderer already drives morph animations the same way and it works, the same pattern works here — no additional changes needed.

- [ ] **Step 6: Build to verify compile**

```bash
xcodebuild -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | grep -E "error:|warning:" | head -20
```

Expected: no compile errors. (The renderer changes are still invisible to users — UI in Task 4 wires this up.)

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Rendering/SculptRenderer.swift
git commit -m "$(cat <<'EOF'
feat(perspective): self-driven 0.3s transition animation in renderer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: UI Toggle Button in SculptScreen

**Files:**
- Modify: `PenSculpt/Views/SculptScreen.swift`

- [ ] **Step 1: Read the SculptScreen toolbar structure**

Open `PenSculpt/Views/SculptScreen.swift` and find the toolbar items (look for `rotate.3d` around line 181 and surrounding buttons). Identify the natural insertion point — between `rotate.3d` and the next button (eraser/deform, around lines 196-224).

- [ ] **Step 2: Add state properties at top of SculptScreen**

Find the `@State` declarations near the top of the struct (where `surfaceSpaceStrokes`, `isRotateMode`, etc. live). Add:

```swift
@State private var projectionMode: SculptRenderer.ProjectionMode = .orthographic
@State private var perspectiveFOV: Float = .pi / 180 * 50
@State private var showFOVPopover: Bool = false
```

- [ ] **Step 3: Add the toggle button**

Find the toolbar HStack containing `rotate.3d`. Right after that button, insert:

```swift
Button {
    let newMode: SculptRenderer.ProjectionMode =
        (projectionMode == .orthographic) ? .perspective : .orthographic
    projectionMode = newMode
    renderer.setProjectionMode(newMode, animated: true)
    if newMode == .orthographic {
        showFOVPopover = false  // close popover if user toggles off perspective
    }
} label: {
    Image(systemName: projectionMode == .perspective ? "cube.transparent.fill" : "cube.transparent")
        .font(.headline)
        .frame(width: 44, height: 44)
}
.simultaneousGesture(
    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
        if projectionMode == .perspective {
            showFOVPopover = true
        }
        // long-press in ortho: no-op (the spec calls this out)
    }
)
```

Adjust `renderer` to whatever the existing reference is called — search the file for `SculptRenderer` to find the right binding name (e.g., `viewModel.renderer`, `sculptRenderer`, etc.).

- [ ] **Step 4: Build and run on iPad simulator to confirm button appears**

```bash
xcodebuild -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | grep -E "error:" | head -10
```

Expected: no compile errors.

Manual check: open the simulator, enter Sculpt, confirm the new button appears in the toolbar next to `rotate.3d`. Tap it — the projection should switch (mesh visibly changes with subtle perspective convergence). Tap again, returns to ortho. (No FOV slider yet — that's Task 5.)

If the icon doesn't read well as "ortho vs perspective", swap to alternatives:
- Try `view.3d` / `view.3d.fill`
- Try `cube` / `cube.fill`
- Pick whatever communicates better visually.

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Views/SculptScreen.swift
git commit -m "$(cat <<'EOF'
feat(perspective): add projection toggle button to Sculpt toolbar

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: FOV Popover with Slider

**Files:**
- Modify: `PenSculpt/Views/SculptScreen.swift`

- [ ] **Step 1: Add popover modifier to the toggle button**

Find the toggle button you added in Task 4. Append `.popover(isPresented: $showFOVPopover)`:

```swift
.popover(isPresented: $showFOVPopover, arrowEdge: .top) {
    VStack(spacing: 12) {
        Text("Field of View")
            .font(.subheadline.weight(.medium))
        HStack {
            Text("20°")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(perspectiveFOV * 180 / .pi) },
                    set: { newDegrees in
                        perspectiveFOV = Float(newDegrees) * .pi / 180
                        renderer.perspectiveFOV = perspectiveFOV
                    }
                ),
                in: 20...90,
                step: 1
            )
            .frame(width: 220)
            Text("90°")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        Text("\(Int(perspectiveFOV * 180 / .pi))°")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
    .padding(16)
    .presentationCompactAdaptation(.popover)
}
```

Again, replace `renderer` with the actual reference.

- [ ] **Step 2: Build to verify compile**

```bash
xcodebuild -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | grep -E "error:" | head -10
```

Expected: no errors.

- [ ] **Step 3: Reset state on Sculpt exit**

The spec says FOV resets to 50° and mode to ortho when the user leaves the Sculpt screen and re-enters. Since the `@State` lives in `SculptScreen`, it resets automatically when the view is recreated.

Verify: in `DrawingScreen.swift`, the `fullScreenCover` presents `SculptScreen` — when dismissed, the SwiftUI view is destroyed and re-created on next presentation, so state resets. **No code change needed** — confirm by reading the existing `fullScreenCover` invocation.

- [ ] **Step 4: Commit**

```bash
git add PenSculpt/Views/SculptScreen.swift
git commit -m "$(cat <<'EOF'
feat(perspective): add long-press FOV slider popover

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Manual Verification on iPad

**Files:** none (verification only)

- [ ] **Step 1: Build and run on physical iPad**

Build the app to the connected iPad (or iPad Pro 13-inch M5 simulator if iPad isn't available).

- [ ] **Step 2: Run the verification checklist from the spec**

Walk through each scenario from `docs/superpowers/specs/2026-05-25-perspective-camera-toggle-design.md` (Testes → "Verificação manual no iPad"):

- [ ] Enter Sculpt → confirm it opens in ortho (mesh looks flat, no perspective convergence)
- [ ] Tap the new button → smooth ~0.3s animation, view transitions to perspective; icon fills
- [ ] Long-press the button → popover appears with FOV slider
- [ ] Drag slider → mesh updates live as you drag (convergence increases with higher FOV)
- [ ] Tap outside popover to dismiss
- [ ] Tap button again → smooth animation back to ortho; icon unfills
- [ ] Tap button once more → returns to perspective with the FOV you previously set (persisted within session)
- [ ] Exit Sculpt (X button) and re-enter → starts in ortho with FOV default (50°)
- [ ] Two-finger rotation (arcball) works identically in both ortho and perspective
- [ ] Drawing on the surface still hits the correct mesh point in perspective (try a stroke in perspective mode, confirm it lands where you intended)

- [ ] **Step 3: Record any issues**

Accumulate observations per [[feedback_batch_fixes]] — don't fix piecemeal. If issues are found, document them and apply fixes in one round.

- [ ] **Step 4: If issues found, fix and re-verify**

Apply all fixes in a single commit:

```bash
git add PenSculpt/...  # whichever files changed
git commit -m "fix(perspective): address manual test findings"
```

Re-run the checklist after fixes.

- [ ] **Step 5: Push to both remotes**

Per [[push_to_timosci]], push to both origin and upstream:

```bash
git push origin alexandre
git push upstream alexandre
```

- [ ] **Step 6: Update TODO.md**

In `TODO.md`, change:
```
- [ ] Perspective camera toggle — O[ ] S[ ]
```
to:
```
- [x] Perspective camera toggle — O[ ] S[ ]
```

Commit and push:

```bash
git add TODO.md
git commit -m "$(cat <<'EOF'
docs: mark perspective camera toggle as shipped

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin alexandre
git push upstream alexandre
```
