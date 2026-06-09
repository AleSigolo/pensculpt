# Smart Selector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hold-to-grow "smart" selection strategy that snaps whole drawn objects into the selection nearest-first while the finger is held, alongside the existing lasso.

**Architecture:** Pure, testable logic (`StrokeClustering`, `SmartSelection`) mirrors the existing `LassoSelection` pattern. The existing `LassoOverlay`/`LassoView` is renamed to `SelectionOverlay`/`SelectionView` and becomes the single owner of all Select-mode touches: it disambiguates drag (→ lasso) from stationary hold (→ smart-grow). A smart selection commits into the same `selectedStrokeIDs` as lasso, so everything downstream is unchanged.

**Tech Stack:** Swift 5.9, iOS 17, SwiftUI + UIKit (`UIViewRepresentable`), `CADisplayLink`, `UIImpactFeedbackGenerator`, XCTest. Project is generated with XcodeGen (`project.yml`); new files are picked up only after `xcodegen generate`.

---

## Background for the implementer

- **Pure logic lives in `PenSculpt/Drawing/`** as `enum` types with `static` functions (see `LassoSelection.swift`). Follow this exactly. (Note: `AGENTS.md` mentions a `Selection/` directory, but the real code keeps selection logic in `Drawing/` — follow the real code.)
- **Coordinate spaces:** the overlay view draws in its own "display" coordinates but hit-tests/measures strokes in the `PKCanvasView`'s "target/canvas" coordinates. `Stroke.points[i].location` is in canvas coordinates. The view converts a touch to canvas coords via `touch.location(in: targetView)`. Existing lasso code keeps two parallel arrays (`displayPoints`, `hitTestPoints`) for this reason — smart-grow follows the same split: measure distances in canvas coords, draw the ring/highlights in display coords.
- **Stroke model:** `Stroke` has `id: UUID`, `points: [StrokePoint]`, `boundingBox: CGRect`. `StrokePoint` has `location: CGPoint`. `CGRect` has `.union(_:)`, `.insetBy(dx:dy:)`, `.intersects(_:)`.
- **Test convention:** one test file per source file in `PenSculptTests/`, XCTest (`final class … : XCTestCase`, `func testX()`, `XCTAssert…`).
- **Test command** (run after each task; `xcodegen generate` first when new files were added):

```bash
xcodegen generate
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/<ClassName>
```

If `iPad Pro 13-inch (M5)` is unavailable, substitute any available iPad simulator from `xcrun simctl list devices available`.

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `PenSculpt/Models/StrokeGroup.swift` | A cluster of strokes treated as one object | Create |
| `PenSculpt/Models/SelectionStrategyKind.swift` | `enum { lasso, smart }` — which strategy is active | Create |
| `PenSculpt/Models/SelectionConfig.swift` | Tunable constants (link distance, growth rate, hold delay, slop) | Create |
| `PenSculpt/Drawing/StrokeClustering.swift` | Group strokes into objects by ink proximity (union-find) | Create |
| `PenSculpt/Drawing/SmartSelection.swift` | Distance-from-hold ordering + reach inclusion | Create |
| `PenSculpt/Drawing/SelectionOverlay.swift` | Renamed from `LassoOverlay.swift`; unified Select-mode overlay | Rename + extend |
| `PenSculpt/Views/SelectionStrategyToggle.swift` | Floating Lasso/Smart sub-toggle shown in Select mode | Create |
| `PenSculpt/Views/DrawingViewModel.swift` | Add `activeStrategy`, smart commit handler | Modify |
| `PenSculpt/Views/DrawingScreen.swift` | Mount `SelectionOverlay`, pass strokes/strategy, show toggle | Modify |
| `PenSculptTests/StrokeGroupTests.swift` | Tests for the model | Create |
| `PenSculptTests/StrokeClusteringTests.swift` | Tests for clustering | Create |
| `PenSculptTests/SmartSelectionTests.swift` | Tests for distance/reach logic | Create |
| `PenSculptTests/SelectionViewTests.swift` | Renamed from `LassoViewTests.swift`; lasso + smart-grow | Rename + extend |
| `PenSculptTests/DrawingViewModelTests.swift` | Add strategy-state tests | Modify |
| `TODO.md`, `guides/` | Status + feature guide | Modify/Create |

---

## Task 1: StrokeGroup model

**Files:**
- Create: `PenSculpt/Models/StrokeGroup.swift`
- Test: `PenSculptTests/StrokeGroupTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PenSculptTests/StrokeGroupTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class StrokeGroupTests: XCTestCase {

    func testStoresStrokeIDsAndBox() {
        let a = UUID(), b = UUID()
        let group = StrokeGroup(strokeIDs: [a, b],
                                boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(group.strokeIDs, [a, b])
        XCTAssertEqual(group.boundingBox, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testHasStableIdentity() {
        let id = UUID()
        let group = StrokeGroup(id: id, strokeIDs: [], boundingBox: .zero)
        XCTAssertEqual(group.id, id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:PenSculptTests/StrokeGroupTests`
Expected: FAIL — "cannot find 'StrokeGroup' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `PenSculpt/Models/StrokeGroup.swift`:

```swift
import Foundation

/// A cluster of strokes that are spatially close enough to be treated as
/// one drawn object by the smart selector.
struct StrokeGroup: Identifiable, Equatable {
    let id: UUID
    let strokeIDs: Set<UUID>
    let boundingBox: CGRect

    init(id: UUID = UUID(), strokeIDs: Set<UUID>, boundingBox: CGRect) {
        self.id = id
        self.strokeIDs = strokeIDs
        self.boundingBox = boundingBox
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command as Step 2.
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Models/StrokeGroup.swift PenSculptTests/StrokeGroupTests.swift PenSculpt.xcodeproj
git commit -m "feat: add StrokeGroup model for smart selection clusters"
```

---

## Task 2: SelectionConfig + SelectionStrategyKind

**Files:**
- Create: `PenSculpt/Models/SelectionConfig.swift`
- Create: `PenSculpt/Models/SelectionStrategyKind.swift`
- Test: `PenSculptTests/SelectionConfigTests.swift`

These are plain value declarations. One small test pins the defaults so accidental edits are caught.

- [ ] **Step 1: Write the failing test**

Create `PenSculptTests/SelectionConfigTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class SelectionConfigTests: XCTestCase {

    func testDefaultsAreSane() {
        XCTAssertGreaterThan(SelectionConfig.clusterLinkDistance, 0)
        XCTAssertGreaterThan(SelectionConfig.growthRate, 0)
        XCTAssertGreaterThan(SelectionConfig.holdDelay, 0)
        XCTAssertGreaterThan(SelectionConfig.moveSlop, 0)
    }

    func testStrategyKindHasTwoCases() {
        XCTAssertNotEqual(SelectionStrategyKind.lasso, SelectionStrategyKind.smart)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test … -only-testing:PenSculptTests/SelectionConfigTests`
Expected: FAIL — "cannot find 'SelectionConfig' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `PenSculpt/Models/SelectionConfig.swift`:

```swift
import Foundation

/// Tunable parameters for selection gestures. First-guess values — tune on a
/// physical iPad (smart-grow feel cannot be judged in the simulator).
enum SelectionConfig {
    /// Max ink gap (points) for two strokes to be treated as one object.
    static let clusterLinkDistance: CGFloat = 24
    /// Reach-radius expansion speed in points per second.
    static let growthRate: CGFloat = 700
    /// Stationary time (seconds) before smart-grow activates from a lasso touch.
    static let holdDelay: TimeInterval = 0.3
    /// Movement tolerance (points) distinguishing a drag (lasso) from a hold (smart).
    static let moveSlop: CGFloat = 10
}
```

Create `PenSculpt/Models/SelectionStrategyKind.swift`:

```swift
import Foundation

/// Which selection strategy is currently active within Select mode.
enum SelectionStrategyKind {
    case lasso
    case smart
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Models/SelectionConfig.swift PenSculpt/Models/SelectionStrategyKind.swift PenSculptTests/SelectionConfigTests.swift PenSculpt.xcodeproj
git commit -m "feat: add SelectionConfig constants and SelectionStrategyKind"
```

---

## Task 3: StrokeClustering

Groups strokes into objects with union-find: a broadphase bounding-box reject, then a narrowphase minimum-point-distance check.

**Files:**
- Create: `PenSculpt/Drawing/StrokeClustering.swift`
- Test: `PenSculptTests/StrokeClusteringTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PenSculptTests/StrokeClusteringTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class StrokeClusteringTests: XCTestCase {

    private func stroke(_ a: CGPoint, _ b: CGPoint) -> Stroke {
        Stroke(points: [
            StrokePoint(location: a, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: b, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
    }

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(StrokeClustering.groups(from: [], linkDistance: 24).isEmpty)
    }

    func testSingleStrokeIsOneGroup() {
        let s = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        let groups = StrokeClustering.groups(from: [s], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokeIDs, [s.id])
    }

    func testNearStrokesMergeIntoOneGroup() {
        // Endpoints 10pt apart, link distance 24 → same object.
        let s1 = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let s2 = stroke(CGPoint(x: 110, y: 0), CGPoint(x: 200, y: 0))
        let groups = StrokeClustering.groups(from: [s1, s2], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokeIDs, [s1.id, s2.id])
    }

    func testFarStrokesStaySeparate() {
        // Endpoints 200pt apart, link distance 24 → two objects.
        let s1 = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let s2 = stroke(CGPoint(x: 300, y: 0), CGPoint(x: 400, y: 0))
        let groups = StrokeClustering.groups(from: [s1, s2], linkDistance: 24)
        XCTAssertEqual(groups.count, 2)
    }

    func testTransitiveChainMergesAll() {
        // A near B, B near C, A far from C → all one group via the chain.
        let a = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0))
        let b = stroke(CGPoint(x: 60, y: 0), CGPoint(x: 110, y: 0))
        let c = stroke(CGPoint(x: 120, y: 0), CGPoint(x: 170, y: 0))
        let groups = StrokeClustering.groups(from: [a, b, c], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokeIDs, [a.id, b.id, c.id])
    }

    func testGroupBoundingBoxIsUnionOfMembers() {
        let s1 = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let s2 = stroke(CGPoint(x: 110, y: 0), CGPoint(x: 200, y: 50))
        let groups = StrokeClustering.groups(from: [s1, s2], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].boundingBox.minX, 0, accuracy: 0.5)
        XCTAssertEqual(groups[0].boundingBox.maxX, 200, accuracy: 0.5)
        XCTAssertEqual(groups[0].boundingBox.maxY, 50, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test … -only-testing:PenSculptTests/StrokeClusteringTests`
Expected: FAIL — "cannot find 'StrokeClustering' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `PenSculpt/Drawing/StrokeClustering.swift`:

```swift
import Foundation

/// Groups strokes into "objects" by ink proximity. Two strokes belong to the
/// same group when the minimum distance between any of their sampled points is
/// within `linkDistance`. Grouping is transitive (connected components).
enum StrokeClustering {

    static func groups(from strokes: [Stroke], linkDistance: CGFloat) -> [StrokeGroup] {
        guard !strokes.isEmpty else { return [] }

        var parent = Array(0..<strokes.count)

        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var node = i
            while parent[node] != node {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Broadphase: inflate each box by linkDistance; if an inflated box does
        // not touch the other's box, the strokes cannot be within linkDistance.
        let inflated = strokes.map { $0.boundingBox.insetBy(dx: -linkDistance, dy: -linkDistance) }

        for i in 0..<strokes.count {
            for j in (i + 1)..<strokes.count {
                guard find(i) != find(j) else { continue }
                guard inflated[i].intersects(strokes[j].boundingBox) else { continue }
                if minDistance(strokes[i], strokes[j]) <= linkDistance {
                    union(i, j)
                }
            }
        }

        var byRoot: [Int: [Int]] = [:]
        for i in 0..<strokes.count {
            byRoot[find(i), default: []].append(i)
        }

        return byRoot.values.map { indices in
            let ids = Set(indices.map { strokes[$0].id })
            let box = indices.dropFirst().reduce(strokes[indices[0]].boundingBox) {
                $0.union(strokes[$1].boundingBox)
            }
            return StrokeGroup(strokeIDs: ids, boundingBox: box)
        }
    }

    /// Minimum Euclidean distance between any sampled point of `a` and `b`.
    /// O(points(a) * points(b)) — acceptable at current stroke counts.
    static func minDistance(_ a: Stroke, _ b: Stroke) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for pa in a.points {
            for pb in b.points {
                let dx = pa.location.x - pb.location.x
                let dy = pa.location.y - pb.location.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < best { best = d }
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Drawing/StrokeClustering.swift PenSculptTests/StrokeClusteringTests.swift PenSculpt.xcodeproj
git commit -m "feat: cluster strokes into objects by ink proximity"
```

---

## Task 4: SmartSelection

Distance-from-hold ordering and reach-radius inclusion.

**Files:**
- Create: `PenSculpt/Drawing/SmartSelection.swift`
- Test: `PenSculptTests/SmartSelectionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PenSculptTests/SmartSelectionTests.swift`:

```swift
import XCTest
@testable import PenSculpt

final class SmartSelectionTests: XCTestCase {

    private func stroke(_ a: CGPoint, _ b: CGPoint) -> Stroke {
        Stroke(points: [
            StrokePoint(location: a, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: b, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
    }

    /// near (closest point ~10pt from origin) and far (~100pt from origin).
    private func fixture() -> (strokes: [Stroke], groups: [StrokeGroup], near: Stroke, far: Stroke) {
        let near = stroke(CGPoint(x: 10, y: 0), CGPoint(x: 50, y: 0))
        let far = stroke(CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 0))
        let strokes = [near, far]
        let groups = StrokeClustering.groups(from: strokes, linkDistance: 24)
        return (strokes, groups, near, far)
    }

    func testGroupDistancesUseNearestPoint() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        // Two separate groups (gap 50 > 24).
        XCTAssertEqual(distances.count, 2)
        let nearEntry = distances.first { $0.group.strokeIDs.contains(f.near.id) }
        XCTAssertEqual(nearEntry?.distance ?? -1, 10, accuracy: 0.5)
    }

    func testNearestDistanceIsTheSeed() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        XCTAssertEqual(SmartSelection.nearestDistance(distances), 10, accuracy: 0.5)
    }

    func testReachAtSeedSelectsOnlyNearest() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        let ids = SmartSelection.groupsWithin(reach: 10, distances: distances)
        XCTAssertTrue(ids.contains(f.near.id))
        XCTAssertFalse(ids.contains(f.far.id))
    }

    func testLargerReachPullsInFartherGroup() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        let ids = SmartSelection.groupsWithin(reach: 100, distances: distances)
        XCTAssertTrue(ids.contains(f.near.id))
        XCTAssertTrue(ids.contains(f.far.id))
    }

    func testReachIsMonotonic() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        let small = SmartSelection.groupsWithin(reach: 10, distances: distances)
        let large = SmartSelection.groupsWithin(reach: 100, distances: distances)
        XCTAssertTrue(small.isSubset(of: large))
    }

    func testNoGroupsGivesZeroSeedAndEmptySelection() {
        XCTAssertEqual(SmartSelection.nearestDistance([]), 0, accuracy: 0.0001)
        XCTAssertTrue(SmartSelection.groupsWithin(reach: 999, distances: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test … -only-testing:PenSculptTests/SmartSelectionTests`
Expected: FAIL — "cannot find 'SmartSelection' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `PenSculpt/Drawing/SmartSelection.swift`:

```swift
import Foundation

/// Reach-based selection: groups are ordered by distance from the hold point
/// and pulled in (whole) once the growing reach radius reaches them.
enum SmartSelection {

    /// Pairs each group with the distance from `holdPoint` to its nearest ink
    /// point. `holdPoint` and stroke locations must be in the same coordinate
    /// space (canvas coordinates).
    static func groupDistances(
        groups: [StrokeGroup],
        strokes: [Stroke],
        from holdPoint: CGPoint
    ) -> [(group: StrokeGroup, distance: CGFloat)] {
        let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.map { group in
            var best = CGFloat.greatestFiniteMagnitude
            for id in group.strokeIDs {
                guard let stroke = byID[id] else { continue }
                for p in stroke.points {
                    let dx = p.location.x - holdPoint.x
                    let dy = p.location.y - holdPoint.y
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < best { best = d }
                }
            }
            return (group, best)
        }
    }

    /// Distance to the nearest group — the seed reach. Zero when there are no groups.
    static func nearestDistance(
        _ distances: [(group: StrokeGroup, distance: CGFloat)]
    ) -> CGFloat {
        distances.map { $0.distance }.min() ?? 0
    }

    /// Stroke IDs of every group whose nearest point is within `reach`.
    static func groupsWithin(
        reach: CGFloat,
        distances: [(group: StrokeGroup, distance: CGFloat)]
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in distances where entry.distance <= reach {
            ids.formUnion(entry.group.strokeIDs)
        }
        return ids
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Drawing/SmartSelection.swift PenSculptTests/SmartSelectionTests.swift PenSculpt.xcodeproj
git commit -m "feat: add reach-based smart selection distance logic"
```

---

## Task 5: DrawingViewModel strategy state

**Files:**
- Modify: `PenSculpt/Views/DrawingViewModel.swift`
- Test: `PenSculptTests/DrawingViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Append these tests inside `DrawingViewModelTests` (before the final closing brace), after the `// MARK: - Selection` block:

```swift
    // MARK: - Selection strategy

    func testDefaultStrategyIsLasso() {
        let vm = makeVM()
        XCTAssertEqual(vm.activeStrategy, .lasso)
    }

    func testActivateSmartStrategy() {
        let vm = makeVM()
        vm.activateSmartStrategy()
        XCTAssertEqual(vm.activeStrategy, .smart)
    }

    func testHandleSmartSelectCommittedSetsSelection() {
        let vm = makeVM()
        let s1 = makeStroke(at: CGPoint(x: 10, y: 10))
        let s2 = makeStroke(at: CGPoint(x: 500, y: 500))
        vm.addStroke(s1)
        vm.addStroke(s2)

        vm.handleSmartSelectCommitted(strokeIDs: [s1.id])

        XCTAssertEqual(vm.selectedStrokeIDs, [s1.id])
    }

    func testToggleToDrawResetsStrategyToLasso() {
        let vm = makeVM()
        vm.toggleMode()                // → select
        vm.activateSmartStrategy()     // → smart
        vm.toggleMode()                // → draw
        XCTAssertEqual(vm.activeStrategy, .lasso)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:PenSculptTests/DrawingViewModelTests`
Expected: FAIL — "value of type 'DrawingViewModel' has no member 'activeStrategy'".

- [ ] **Step 3: Write minimal implementation**

In `PenSculpt/Views/DrawingViewModel.swift`, add the property next to the other selection state (after `var selectedStrokeIDs: Set<UUID> = []`):

```swift
    var activeStrategy: SelectionStrategyKind = .lasso
```

In `toggleMode()`, reset the strategy when returning to draw. Replace the existing `else` branch:

```swift
    func toggleMode() {
        if appMode == .draw {
            appMode = .select
        } else {
            appMode = .draw
            lassoPoints = []
            selectedStrokeIDs = []
            activeStrategy = .lasso
        }
    }
```

In the `// MARK: - Selection` section, add below `handleLassoCompleted`:

```swift
    func activateSmartStrategy() {
        activeStrategy = .smart
    }

    func handleSmartSelectCommitted(strokeIDs: Set<UUID>) {
        selectedStrokeIDs = strokeIDs
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (all `DrawingViewModelTests`, including the 4 new ones).

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Views/DrawingViewModel.swift PenSculptTests/DrawingViewModelTests.swift
git commit -m "feat: track active selection strategy in DrawingViewModel"
```

---

## Task 6: Rename LassoOverlay → SelectionOverlay (refactor, no behavior change)

This is a pure rename so the unified overlay can own both gestures. Keep all lasso behavior; only type/file names change. Existing lasso tests must stay green.

**Files:**
- Rename: `PenSculpt/Drawing/LassoOverlay.swift` → `PenSculpt/Drawing/SelectionOverlay.swift`
- Rename: `PenSculptTests/LassoViewTests.swift` → `PenSculptTests/SelectionViewTests.swift`
- Modify: `PenSculpt/Views/DrawingScreen.swift` (reference the new type)
- Modify: `PenSculptTests/LassoSelectionTests.swift` (one `LassoView` reference)

- [ ] **Step 1: Rename the files with git**

```bash
git mv PenSculpt/Drawing/LassoOverlay.swift PenSculpt/Drawing/SelectionOverlay.swift
git mv PenSculptTests/LassoViewTests.swift PenSculptTests/SelectionViewTests.swift
```

- [ ] **Step 2: Rename the types in `SelectionOverlay.swift`**

In `PenSculpt/Drawing/SelectionOverlay.swift`, rename `struct LassoOverlay` → `struct SelectionOverlay` and `class LassoView` → `class SelectionView`. The `Coordinator`'s `parent` type becomes `SelectionOverlay`, and `makeUIView`/`updateUIView` return/take `SelectionView`. Leave all method bodies (`beginStroke`, `continueStroke`, `endStroke`, `clearLasso`, `draw`, touch handlers, `displayPoints`/`hitTestPoints`) unchanged.

- [ ] **Step 3: Update references in `SelectionViewTests.swift`**

In `PenSculptTests/SelectionViewTests.swift`, rename the class to `SelectionViewTests`, and replace every `LassoView` with `SelectionView` and every `LassoOverlay` with `SelectionOverlay` (the `makeLassoView()` helper, the `LassoOverlay(...)` / `LassoOverlay.Coordinator(...)` constructions in `testCompletionCallbackReceivesHitTestPoints` and `testNoCallbackWhenTooFewPoints`). Optionally rename `makeLassoView()` → `makeSelectionView()`.

- [ ] **Step 4: Update the one reference in `LassoSelectionTests.swift`**

In `PenSculptTests/LassoSelectionTests.swift`, `testViewBridgeCoordinateConversion` constructs `let lassoView = LassoView()`. Change `LassoView()` → `SelectionView()`. (Leave the local variable name and the rest of the file as-is.)

- [ ] **Step 5: Update `DrawingScreen.swift`**

In `PenSculpt/Views/DrawingScreen.swift`, in `selectModeOverlay`, change `LassoOverlay(` → `SelectionOverlay(`. Leave the arguments unchanged for now (smart wiring comes in Task 8).

- [ ] **Step 6: Regenerate, build, and run the affected tests**

Run:
```bash
xcodegen generate && xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:PenSculptTests/SelectionViewTests -only-testing:PenSculptTests/LassoSelectionTests
```
Expected: PASS (all renamed lasso tests — same count as before, no behavior change).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename LassoOverlay/LassoView to SelectionOverlay/SelectionView"
```

---

## Task 7: Smart-grow state machine on SelectionView

Add the pure, testable smart-grow methods to `SelectionView`. No touch handling or display link yet — just the state transitions, mirroring how the lasso `beginStroke`/`continueStroke`/`endStroke` methods are unit-tested directly.

**Files:**
- Modify: `PenSculpt/Drawing/SelectionOverlay.swift`
- Test: `PenSculptTests/SelectionViewTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SelectionViewTests` (before the final closing brace):

```swift
    // MARK: - Smart-grow state machine

    private func smartStroke(_ a: CGPoint, _ b: CGPoint) -> Stroke {
        Stroke(points: [
            StrokePoint(location: a, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: b, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
    }

    func testIsWithinSlop() {
        XCTAssertTrue(SelectionView.isWithinSlop(movement: 5, slop: 10))
        XCTAssertFalse(SelectionView.isWithinSlop(movement: 15, slop: 10))
    }

    func testBeginSmartGrowSeedsNearestObject() {
        let view = makeSelectionView()
        let near = smartStroke(CGPoint(x: 10, y: 0), CGPoint(x: 50, y: 0))
        let far = smartStroke(CGPoint(x: 300, y: 0), CGPoint(x: 350, y: 0))
        view.strokes = [near, far]

        // hold point at canvas origin; display point arbitrary
        view.beginSmartGrow(displayPoint: CGPoint(x: 5, y: 5), targetPoint: .zero)

        // Seed reach = nearest distance (~10) → only the near object is selected.
        XCTAssertTrue(view.smartSelectedIDs.contains(near.id))
        XCTAssertFalse(view.smartSelectedIDs.contains(far.id))
    }

    func testAdvanceSmartGrowPullsInFartherObjectAndReportsGrowth() {
        let view = makeSelectionView()
        let near = smartStroke(CGPoint(x: 10, y: 0), CGPoint(x: 50, y: 0))
        let far = smartStroke(CGPoint(x: 300, y: 0), CGPoint(x: 350, y: 0))
        view.strokes = [near, far]
        view.beginSmartGrow(displayPoint: .zero, targetPoint: .zero)

        let grewSmall = view.advanceSmartGrow(reach: 50)   // still only near
        XCTAssertFalse(grewSmall)
        XCTAssertFalse(view.smartSelectedIDs.contains(far.id))

        let grewLarge = view.advanceSmartGrow(reach: 320)  // far joins (~300)
        XCTAssertTrue(grewLarge)
        XCTAssertTrue(view.smartSelectedIDs.contains(far.id))
    }

    func testEndSmartGrowReturnsCommittedIDsAndClearsReach() {
        let view = makeSelectionView()
        let near = smartStroke(CGPoint(x: 10, y: 0), CGPoint(x: 50, y: 0))
        view.strokes = [near]
        view.beginSmartGrow(displayPoint: .zero, targetPoint: .zero)

        let committed = view.endSmartGrow()
        XCTAssertEqual(committed, [near.id])
        XCTAssertTrue(view.smartSelectedIDs.isEmpty)
        XCTAssertNil(view.smartHoldDisplayPoint)
    }

    func testSmartGrowWithNoStrokesSelectsNothing() {
        let view = makeSelectionView()
        view.strokes = []
        view.beginSmartGrow(displayPoint: .zero, targetPoint: .zero)
        _ = view.advanceSmartGrow(reach: 9999)
        XCTAssertTrue(view.smartSelectedIDs.isEmpty)
        XCTAssertTrue(view.endSmartGrow().isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test … -only-testing:PenSculptTests/SelectionViewTests`
Expected: FAIL — "type 'SelectionView' has no member 'isWithinSlop'" / "no member 'beginSmartGrow'".

- [ ] **Step 3: Write minimal implementation**

In `PenSculpt/Drawing/SelectionOverlay.swift`, add to `class SelectionView` (alongside the lasso state). Add these stored properties near `displayPoints`:

```swift
    // MARK: - Smart-grow state

    /// Snapshot of canvas strokes (canvas coordinates) for clustering + drawing.
    var strokes: [Stroke] = []
    /// Reach-ring center in this view's (display) coordinates; nil when inactive.
    private(set) var smartHoldDisplayPoint: CGPoint?
    /// Current reach radius (canvas-space distance) for drawing the ring.
    private(set) var smartReach: CGFloat = 0
    /// Stroke IDs currently inside the reach.
    private(set) var smartSelectedIDs: Set<UUID> = []

    private var smartDistances: [(group: StrokeGroup, distance: CGFloat)] = []
```

Add these methods to `SelectionView`:

```swift
    /// Whether a touch that has moved `movement` points still counts as a hold.
    static func isWithinSlop(movement: CGFloat, slop: CGFloat) -> Bool {
        movement <= slop
    }

    /// Begin smart-grow: cluster the snapshot, seed at the nearest object.
    /// `targetPoint` is in canvas coordinates; `displayPoint` in view coordinates.
    func beginSmartGrow(displayPoint: CGPoint, targetPoint: CGPoint) {
        clearLasso()
        smartHoldDisplayPoint = displayPoint
        let groups = StrokeClustering.groups(from: strokes,
                                             linkDistance: SelectionConfig.clusterLinkDistance)
        smartDistances = SmartSelection.groupDistances(groups: groups, strokes: strokes,
                                                       from: targetPoint)
        smartReach = SmartSelection.nearestDistance(smartDistances)
        smartSelectedIDs = SmartSelection.groupsWithin(reach: smartReach, distances: smartDistances)
        setNeedsDisplay()
    }

    /// Grow the reach. Returns true when new strokes were pulled in (for haptics).
    @discardableResult
    func advanceSmartGrow(reach: CGFloat) -> Bool {
        smartReach = reach
        let updated = SmartSelection.groupsWithin(reach: reach, distances: smartDistances)
        let grew = !updated.subtracting(smartSelectedIDs).isEmpty
        smartSelectedIDs = updated
        setNeedsDisplay()
        return grew
    }

    /// Finish smart-grow, returning the committed stroke IDs and clearing state.
    func endSmartGrow() -> Set<UUID> {
        let committed = smartSelectedIDs
        smartHoldDisplayPoint = nil
        smartReach = 0
        smartDistances = []
        smartSelectedIDs = []
        setNeedsDisplay()
        return committed
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the Step 2 command. Expected: PASS (existing lasso tests + 5 new smart-grow tests).

- [ ] **Step 5: Commit**

```bash
git add PenSculpt/Drawing/SelectionOverlay.swift PenSculptTests/SelectionViewTests.swift
git commit -m "feat: add smart-grow state machine to SelectionView"
```

---

## Task 8: SelectionView touch handling, display link, drawing & haptics

Wire the real gesture. This is UIKit glue (touches, `CADisplayLink`, `draw`, haptics) that is verified manually on device, not unit-tested. The decision logic it calls (`isWithinSlop`, `beginSmartGrow`, `advanceSmartGrow`, `endSmartGrow`) is already tested.

**Behavior:**
- `activeStrategy == .smart`: touch-down begins smart-grow immediately at the touch point.
- `activeStrategy == .lasso`: touch-down tentatively begins a lasso AND starts a hold timer. If the touch moves beyond `moveSlop` first → it stays a lasso (cancel timer). If the hold timer fires first → switch to smart (notify parent, begin smart-grow).
- While growing, a `CADisplayLink` expands `reach = seedReach + growthRate * elapsed`; each new object fires a `.light` haptic. The view draws an expanding ring + blue highlights over in-progress strokes.
- Touch-up commits via `onSmartSelectCompleted`.

**Files:**
- Modify: `PenSculpt/Drawing/SelectionOverlay.swift`

- [ ] **Step 1: Add overlay inputs + coordinator wiring**

In `struct SelectionOverlay`, add stored inputs and pass them to the view. Replace the struct's properties and `makeUIView`/`updateUIView`:

```swift
struct SelectionOverlay: UIViewRepresentable {
    @Binding var lassoPoints: [CGPoint]
    var onLassoCompleted: ([CGPoint]) -> Void
    var strokes: [Stroke] = []
    var activeStrategy: SelectionStrategyKind = .lasso
    var onSmartActivated: () -> Void = {}
    var onSmartSelectCompleted: (Set<UUID>) -> Void = { _ in }
    var viewBridge: ViewBridge?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SelectionView {
        let view = SelectionView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SelectionView, context: Context) {
        context.coordinator.parent = self
        uiView.targetView = viewBridge?.canvasView
        uiView.strokes = strokes
        uiView.activeStrategy = activeStrategy
        if lassoPoints.isEmpty && !uiView.displayPoints.isEmpty {
            uiView.clearLasso()
        }
    }

    class Coordinator {
        var parent: SelectionOverlay
        init(_ parent: SelectionOverlay) { self.parent = parent }
    }
}
```

- [ ] **Step 2: Add gesture/animation state to `SelectionView`**

Add these stored properties to `SelectionView`:

```swift
    var activeStrategy: SelectionStrategyKind = .lasso

    private var holdTimer: Timer?
    private var displayLink: CADisplayLink?
    private var touchStartDisplay: CGPoint = .zero
    private var touchStartTarget: CGPoint = .zero
    private var growthStartTime: CFTimeInterval = 0
    private var seedReach: CGFloat = 0
    private var isSmartGrowing = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)
```

- [ ] **Step 3: Replace the touch handlers**

Replace the existing `touchesBegan` / `touchesMoved` / `touchesEnded` in `SelectionView` with:

```swift
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = points(for: touch)
        touchStartDisplay = p.display
        touchStartTarget = p.target

        if activeStrategy == .smart {
            startSmartGrow(display: p.display, target: p.target)
        } else {
            // Tentative lasso; a stationary hold will switch to smart.
            beginStroke(displayPoint: p.display, targetPoint: p.target)
            holdTimer = Timer.scheduledTimer(withTimeInterval: SelectionConfig.holdDelay,
                                             repeats: false) { [weak self] _ in
                self?.handleHoldFired()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = points(for: touch)

        if isSmartGrowing { return } // smart ignores drift; ring stays put

        let dx = p.display.x - touchStartDisplay.x
        let dy = p.display.y - touchStartDisplay.y
        let movement = (dx * dx + dy * dy).squareRoot()
        if !Self.isWithinSlop(movement: movement, slop: SelectionConfig.moveSlop) {
            holdTimer?.invalidate(); holdTimer = nil   // committed to lasso
        }
        continueStroke(displayPoint: p.display, targetPoint: p.target)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate(); holdTimer = nil
        if isSmartGrowing {
            finishSmartGrow()
        } else {
            endStroke()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate(); holdTimer = nil
        if isSmartGrowing {
            stopDisplayLink()
            _ = endSmartGrow()
            isSmartGrowing = false
        } else {
            clearLasso()
        }
    }
```

- [ ] **Step 4: Add the smart-grow lifecycle helpers**

Add to `SelectionView`:

```swift
    private func handleHoldFired() {
        guard !isSmartGrowing else { return }
        coordinator?.parent.onSmartActivated()           // flips toggle to .smart
        activeStrategy = .smart
        startSmartGrow(display: touchStartDisplay, target: touchStartTarget)
    }

    private func startSmartGrow(display: CGPoint, target: CGPoint) {
        isSmartGrowing = true
        haptics.prepare()
        beginSmartGrow(displayPoint: display, targetPoint: target)
        seedReach = smartReach
        growthStartTime = CACurrentMediaTime()
        if !smartSelectedIDs.isEmpty { haptics.impactOccurred() }  // seed tick
        startDisplayLink()
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(stepGrowth))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func stepGrowth() {
        let elapsed = CGFloat(CACurrentMediaTime() - growthStartTime)
        let reach = seedReach + SelectionConfig.growthRate * elapsed
        if advanceSmartGrow(reach: reach) {
            haptics.impactOccurred()                      // tick per new object
        }
    }

    private func finishSmartGrow() {
        stopDisplayLink()
        let committed = endSmartGrow()
        isSmartGrowing = false
        coordinator?.parent.onSmartSelectCompleted(committed)
    }
```

- [ ] **Step 5: Draw the reach ring + in-progress highlights**

Replace `SelectionView`'s `draw(_:)` with a version that keeps the existing lasso rendering and adds smart visuals:

```swift
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Smart-grow visuals
        if let center = smartHoldDisplayPoint {
            // In-progress object highlights (blue), converted canvas → display.
            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes where smartSelectedIDs.contains(stroke.id) && stroke.points.count > 1 {
                ctx.beginPath()
                ctx.move(to: convertFromTarget(stroke.points[0].location))
                for point in stroke.points.dropFirst() {
                    ctx.addLine(to: convertFromTarget(point.location))
                }
                ctx.strokePath()
            }
            // Reach ring (reach is a canvas-space radius; canvas↔display are
            // same-scale sibling views, so it maps 1:1).
            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [])
            let r = max(smartReach, 1)
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }

        // Lasso path (unchanged)
        guard displayPoints.count > 1 else { return }
        ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 4])
        ctx.beginPath()
        ctx.move(to: displayPoints[0])
        for point in displayPoints.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.strokePath()
    }

    /// Converts a point from target (canvas) coordinates into this view's coordinates.
    private func convertFromTarget(_ point: CGPoint) -> CGPoint {
        guard let target = targetView else { return point }
        return target.convert(point, to: self)
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run:
```bash
xcodegen generate && xcodebuild -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: BUILD SUCCEEDED. Then run the unit tests to confirm the extracted-method tests still pass:
```bash
xcodebuild test … -only-testing:PenSculptTests/SelectionViewTests
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Drawing/SelectionOverlay.swift PenSculpt.xcodeproj
git commit -m "feat: wire smart-grow touches, display link, drawing and haptics"
```

---

## Task 9: DrawingScreen integration + strategy toggle UI

Mount the unified overlay with smart inputs, and add a floating Lasso/Smart sub-toggle shown in Select mode. (Design note: the sub-toggle gets its own small view rather than living in `FloatingToolbar`, because `FloatingToolbar` is brush-specific and only shown in draw mode.)

**Files:**
- Create: `PenSculpt/Views/SelectionStrategyToggle.swift`
- Modify: `PenSculpt/Views/DrawingScreen.swift`

- [ ] **Step 1: Create the toggle view**

Create `PenSculpt/Views/SelectionStrategyToggle.swift`:

```swift
import SwiftUI

/// Floating Lasso / Smart sub-toggle shown while in Select mode.
struct SelectionStrategyToggle: View {
    @Binding var strategy: SelectionStrategyKind

    var body: some View {
        HStack(spacing: 12) {
            button(.lasso, systemImage: "lasso", label: "Lasso")
            Divider().frame(height: 24)
            button(.smart, systemImage: "circle.dashed.inset.filled", label: "Smart")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func button(_ kind: SelectionStrategyKind, systemImage: String, label: String) -> some View {
        Button {
            strategy = kind
        } label: {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(strategy == kind ? .primary : .secondary)
        }
    }
}
```

- [ ] **Step 2: Make `SelectionStrategyKind` usable in SwiftUI state**

`@Binding`/comparison need `Equatable`. Update `PenSculpt/Models/SelectionStrategyKind.swift`:

```swift
import Foundation

/// Which selection strategy is currently active within Select mode.
enum SelectionStrategyKind: Equatable {
    case lasso
    case smart
}
```

(The `SelectionConfigTests.testStrategyKindHasTwoCases` test already exercises `!=`, so this stays green.)

- [ ] **Step 3: Pass smart inputs into the overlay**

In `PenSculpt/Views/DrawingScreen.swift`, replace `selectModeOverlay` with:

```swift
    @ViewBuilder
    private var selectModeOverlay: some View {
        if vm.appMode == .select {
            SelectionOverlay(
                lassoPoints: $vm.lassoPoints,
                onLassoCompleted: { vm.handleLassoCompleted(polygon: $0) },
                strokes: vm.canvas.strokes,
                activeStrategy: vm.activeStrategy,
                onSmartActivated: { vm.activateSmartStrategy() },
                onSmartSelectCompleted: { vm.handleSmartSelectCommitted(strokeIDs: $0) },
                viewBridge: viewBridge
            )
            .ignoresSafeArea()
        }
    }
```

- [ ] **Step 4: Show the strategy toggle in Select mode**

In `DrawingScreen.swift`, add the toggle to the main `ZStack` (in `body`). Add this line right after `selectModeOverlay`:

```swift
            if vm.appMode == .select { selectStrategyControls }
```

Then add the subview (next to `selectModeOverlay`):

```swift
    @ViewBuilder
    private var selectStrategyControls: some View {
        SelectionStrategyToggle(strategy: $vm.activeStrategy)
            .padding(.bottom, vm.hasSelection ? 96 : 30)
    }
```

(The extra bottom padding when there's a selection keeps the toggle clear of the Sculpt button.)

- [ ] **Step 5: Build to verify it compiles**

Run:
```bash
xcodegen generate && xcodebuild -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Manual verification on a physical iPad**

Build/run on device. Verify:
1. Enter Select mode → the Lasso/Smart toggle appears.
2. With **Lasso** active, a drag draws a lasso and selects (unchanged behavior).
3. With **Lasso** active, press and hold still on/near a drawing → after ~0.3s the toggle flips to **Smart**, a ring appears and expands, the nearest object highlights immediately, farther objects pop in as the ring reaches them, with a light haptic per object. Release commits the highlighted strokes (Sculpt button appears).
4. Tap **Smart** in the toggle, then press and hold → smart-grow starts immediately on touch-down (no 0.3s wait).
5. Release at the right moment selects the intended objects; the committed selection is highlighted by the existing `SelectionHighlight`.

- [ ] **Step 7: Commit**

```bash
git add PenSculpt/Views/SelectionStrategyToggle.swift PenSculpt/Views/DrawingScreen.swift PenSculpt/Models/SelectionStrategyKind.swift PenSculpt.xcodeproj
git commit -m "feat: integrate smart selector overlay and strategy toggle into DrawingScreen"
```

---

## Task 10: Full test pass, TODO + guide

**Files:**
- Modify: `TODO.md`
- Create: `guides/<NN>-smart-selector.md` (use the next available numeric prefix in `guides/`)

- [ ] **Step 1: Run the full test suite**

Run:
```bash
xcodegen generate && xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```
Expected: PASS (all suites green).

- [ ] **Step 2: Update `TODO.md`**

Under `### Selection System`, add:

```markdown
- [x] StrokeGroup model — O[ ] S[ ]
- [x] StrokeClustering (union-find, ink-proximity) — O[ ] S[ ]   <!-- O[ ]: O(n²) pair scan; spatial grid TODO -->
- [x] SmartSelection (reach-based, seed-at-nearest) — O[ ] S[ ]
- [x] Smart selector gesture (hold-to-grow, ring + haptics) — O[ ] S[ ]
- [x] Selection strategy toggle (Lasso/Smart, long-press auto-switch) — O[ ] S[ ]
```

Also mark the previously-unchecked `SelectionStrategy protocol` / `StrokeGroup model` lines as done if present (the strategy is now realized via `SelectionStrategyKind` + the unified overlay).

- [ ] **Step 3: Write the feature guide**

Create `guides/<NN>-smart-selector.md` describing: what the smart selector does, how to use it (toggle + long-press), the clustering rule (`clusterLinkDistance`), the growth model (seed-at-nearest, `growthRate`, monotonic), and the tunable constants in `SelectionConfig`. Note that feel must be tuned on a physical iPad.

- [ ] **Step 4: Commit**

```bash
git add TODO.md guides/
git commit -m "docs: record smart selector in TODO and guides"
```

---

## Self-review notes (resolved)

- **Spec coverage:** clustering (Task 3), reach/seed/monotonic growth (Task 4), per-object snapping (Tasks 3-4 + view), unified overlay disambiguation (Tasks 6-8), toggle + long-press auto-switch (Tasks 5, 8, 9), ring + highlight + haptic feedback (Task 8), commit into `selectedStrokeIDs` (Tasks 5, 9), constants (Task 2), edge cases — empty canvas (Task 7 test), drift ignored (Task 8 `touchesMoved` early-return), monotonic (Task 4 test), quick stationary tap no-op (lasso `endStroke` discard path, Task 6).
- **Deviation from spec:** the sub-toggle is a dedicated `SelectionStrategyToggle` view, not a `FloatingToolbar` modification — `FloatingToolbar` is brush-specific and draw-mode only. Requirement (toggle exists; long-press flips it) is still met.
- **Type consistency:** `SelectionView`/`SelectionOverlay`, `StrokeGroup(strokeIDs:boundingBox:)`, `SmartSelection.groupDistances/nearestDistance/groupsWithin`, `SelectionConfig.{clusterLinkDistance,growthRate,holdDelay,moveSlop}`, VM `activeStrategy`/`activateSmartStrategy()`/`handleSmartSelectCommitted(strokeIDs:)` are used consistently across tasks.
