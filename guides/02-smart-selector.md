# Smart Selector

The smart selector is a second selection strategy alongside the lasso. Instead
of drawing a loop, you **hold a spot** and the selection **grows outward**,
snapping in whole drawn objects nearest-first, until you let go.

## How to use it

1. Enter **Select** mode (the lasso/pencil toggle in the nav bar).
2. A floating **Lasso / Smart** toggle appears at the bottom.
   - **Drag** = lasso (unchanged).
   - **Hold still** = smart-grow. A stationary long-press (~0.3 s) automatically
     flips the toggle to **Smart** and starts growing — you don't have to tap the
     toggle first. You can also tap **Smart** explicitly, after which a touch
     begins growing immediately on touch-down.
3. While you hold, a translucent ring expands from your finger. Each whole object
   the ring reaches lights up blue and gives a light haptic tick.
4. **Release** to commit. The committed strokes become the normal selection
   (same `selectedStrokeIDs` as a lasso), so the Sculpt button and highlights
   behave identically.

## How it works

- **Clustering** (`StrokeClustering`): on gesture start, strokes are grouped into
  "objects" by ink proximity — two strokes join the same object when the minimum
  distance between their ink is within `clusterLinkDistance`. Grouping is
  transitive (connected components via union-find), so a scribble made of many
  overlapping strokes collapses into one object.
- **Growth** (`SmartSelection`): each object is measured by the distance from the
  hold point to its nearest ink point. The reach starts at the nearest object
  (so the closest object snaps in immediately) and expands at `growthRate`
  points/second. Growth is **monotonic** — objects only accumulate; releasing
  commits whatever is highlighted.
- **Gesture** (`SelectionView` in `SelectionOverlay.swift`): one overlay owns all
  Select-mode touches and disambiguates drag-vs-hold. A `CADisplayLink` drives
  the per-frame reach expansion; a `.light` `UIImpactFeedbackGenerator` fires
  each time a new object joins.

## Tunable constants

All live in `SelectionConfig` (`PenSculpt/Models/SelectionConfig.swift`). The
defaults are first guesses — **tune them on a physical iPad**, since the feel of
hold timing, growth speed, and haptics can't be judged in the simulator.

| Constant | Default | Effect |
|----------|---------|--------|
| `clusterLinkDistance` | 24 pt | Larger = more strokes merge into one object. |
| `growthRate` | 700 pt/s | Larger = selection grows faster while held. |
| `holdDelay` | 0.3 s | How long a stationary touch waits before smart activates (lasso mode). |
| `moveSlop` | 10 pt | Movement beyond this commits to lasso instead of hold. |

## Notes / limitations

- The reach ring is drawn as a canvas-space radius mapped 1:1 to the overlay.
  This is correct while the canvas and overlay are same-scale siblings; if canvas
  zoom is ever added, the ring radius would need scaling (highlight paths already
  convert correctly via `UIView.convert`).
- Clustering is `O(n²)` in stroke count (with a bounding-box broadphase). Fine at
  current drawing sizes; a spatial-grid acceleration is tracked as a `TODO` in
  `TODO.md`.
