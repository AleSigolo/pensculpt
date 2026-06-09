# Smart Selector — Design

**Date:** 2026-06-09
**Status:** Approved, ready for implementation planning
**Area:** Stage 2 → Selection System

## Summary

A second selection strategy alongside the existing lasso. The user **holds a
stationary spot** on the canvas and the selection **grows outward over time**,
snapping in whole drawn objects (clusters of nearby strokes) nearest-first,
until they let go. Releasing commits the selection.

The "smart" behavior comes from pre-grouping strokes into objects by ink
proximity, so growth adds *whole objects* as units rather than raw geometry or
individual strokes.

## Goals

- Hold-to-grow selection that accumulates whole objects, nearest-first.
- Time-driven, monotonic growth (hold longer → select more); release to commit.
- Reuse the existing selection result path: a smart selection produces the same
  `selectedStrokeIDs` as a lasso selection, so everything downstream is
  unchanged.
- Fit the planned `SelectionStrategy` abstraction and `StrokeGroup` model.

## Non-goals (YAGNI)

- Spatial-grid acceleration for clustering (O(n²) is acceptable for current
  stroke counts; tracked as an optimization TODO).
- Re-seeding the reach center when the finger drifts after activation.
- Shrinking / reversing growth while held.
- Geodesic (flood-frontier) growth ordering — growth is radial from the hold
  point, which matches the reach-ring visual.

## Decisions (resolved during brainstorming)

| Question | Decision |
|----------|----------|
| What grows? | Proximity flood — grows outward through clusters. |
| Growth driver? | Time-based auto-grow while the finger is held still. |
| Unit added? | Whole clustered objects (snap a complete object in at once). |
| Mode activation? | Sub-toggle within Select mode (Option A) **plus** a stationary long-press that auto-switches the active strategy to Smart and begins growing. |
| Visual feedback? | Expanding reach ring + blue object highlights + a `.light` haptic tick each time a new object joins. |
| Grouping rule? | Distance-between-ink (not draw-time/sequence). |

## Architecture

Mirrors the existing lasso pattern: **pure, testable logic** + a **thin UIView**
for gestures. One unified Select-mode overlay owns all touches and disambiguates
drag-vs-hold, because the long-press auto-switch requires a single view to see
the whole gesture.

### Data model

```swift
struct StrokeGroup: Identifiable {
    let id: UUID
    let strokeIDs: Set<UUID>
    let boundingBox: CGRect   // union of member stroke boxes
}
```

### Pure logic

**`StrokeClustering`** (enum, mirrors `LassoSelection`):

```swift
static func groups(from strokes: [Stroke], linkDistance: CGFloat) -> [StrokeGroup]
```

- Union-find over strokes; union two strokes when they are close enough to be
  one object.
- **Broadphase:** skip a pair unless their bounding boxes (inflated by
  `linkDistance`) intersect.
- **Narrowphase:** union when the minimum distance between any sampled point of
  stroke A and any of stroke B is ≤ `linkDistance`.
- Each connected component becomes one `StrokeGroup`.
- Worst case O(n²) point comparisons — acceptable now; spatial-grid optimization
  is a TODO (`O[ ]`).

**`SmartSelection`** (enum):

```swift
static func groupDistances(
    groups: [StrokeGroup],
    strokes: [Stroke],
    from holdPoint: CGPoint
) -> [(group: StrokeGroup, distance: CGFloat)]

static func groupsWithin(
    reach: CGFloat,
    distances: [(StrokeGroup, CGFloat)]
) -> Set<UUID>   // → stroke IDs
```

- `distance` = nearest ink point of the group to the hold point.
- `reach(t) = nearestDistance + growthRate * elapsed`. Seeding at
  `nearestDistance` makes the closest object pop in immediately on activation;
  further objects join nearest-first as the ring expands.
- Monotonic — reach only grows while held.

### Gesture lifecycle (unified `SelectionView` inside `SelectionOverlay`)

1. `touchesBegan` → record start point, start a hold timer (`holdDelay`),
   tentatively begin a lasso path.
2. `touchesMoved` → if movement exceeds `moveSlop` before the timer fires, it is
   a **lasso**: cancel the hold timer, proceed exactly as today.
3. Hold timer fires (finger stayed within `moveSlop`) → it is **smart**: discard
   the tentative lasso path, set `activeStrategy = .smart` on the VM, snapshot
   clusters, fix the hold point, start a `CADisplayLink`.
4. Each tick → recompute `reach` and the included groups. New group(s) added →
   fire a `.light` `UIImpactFeedbackGenerator` and redraw. Draw the expanding
   reach ring + blue highlights over included groups.
5. `touchesEnded` → stop the display link, commit the included stroke IDs to
   `selectedStrokeIDs`, leave `activeStrategy = .smart` (toggle reflects it).

### Edge cases

- **Empty canvas / no strokes:** nothing seeds; ring still draws; release selects
  nothing.
- **Finger drift after activation:** hold point stays fixed at the activation
  point so distances stay stable; the ring does not chase small drifts.
- **Reach exceeds everything:** growth stops once all groups are included.
- **Quick stationary tap (released before `holdDelay`, no movement):** no-op;
  clears any tentative lasso, selects nothing.

## Components

### New files

- `PenSculpt/Models/StrokeGroup.swift` — group model.
- `PenSculpt/Drawing/StrokeClustering.swift` — pure clustering logic.
- `PenSculpt/Drawing/SmartSelection.swift` — pure reach/distance logic.

### Evolved files

- `LassoOverlay.swift` → `SelectionOverlay.swift` (`SelectionView`): keeps all
  existing lasso touch/draw logic; adds hold-detection, the display-link growth
  loop, reach-ring drawing, and haptics. Lasso behavior is unchanged when
  movement happens first.
- `DrawingViewModel.swift`: add `activeStrategy: SelectionStrategyKind`
  (`enum { lasso, smart }`), `handleSmartSelectCommitted(strokeIDs:)`, and a
  clustering snapshot helper. Committed results flow into the same
  `selectedStrokeIDs`, so highlights / sculpt / etc. treat smart and lasso
  selections identically.
- `FloatingToolbar.swift`: in Select mode, show a Lasso / Smart sub-toggle bound
  to `activeStrategy`; the long-press auto-flips it to Smart.
- `AppMode.swift`: stays binary (`.draw` / `.select`) — strategy is a separate
  axis (Option A).

## Constants (`SelectionConfig`)

First-guess values, to tune on the physical iPad (testing happens on real
hardware, not the simulator):

| Constant | Default | Purpose |
|----------|---------|---------|
| `clusterLinkDistance` | ≈ 24 pt | Max ink gap to treat strokes as one object. |
| `growthRate` | ≈ 700 pt/s | Reach expansion speed. |
| `holdDelay` | ≈ 0.3 s | Stationary time before smart activates. |
| `moveSlop` | ≈ 10 pt | Movement tolerance distinguishing drag from hold. |

## Testing

Mirrors the existing pure-logic test style:

- **`StrokeClustering`:** strokes within / beyond `linkDistance` group correctly;
  disjoint clusters; single stroke; empty input.
- **`SmartSelection`:** distance ordering; reach inclusion boundaries;
  seed-at-nearest pops the closest group immediately; monotonic growth.
- **Gesture disambiguation:** extract the slop-vs-hold-delay decision into a
  testable function (like `LassoView`'s testable `beginStroke` /
  `continueStroke` / `endStroke`), so drag→lasso and hold→smart are unit-tested
  without a live touch.
- Update `TODO.md`: add smart-selector items under Stage 2 → Selection System,
  with `O[ ]` on the O(n²) clustering.
