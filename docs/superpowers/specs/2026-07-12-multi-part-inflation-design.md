# Multi-Part Inflation — Design

**Date:** 2026-07-12
**Status:** Approved design, pending implementation
**Branch context:** builds on `feature/25d-edit-mode` pipeline (ShapeInflater, ContourExtractor, StrokeLifter)

## Problem

The current 2D→3D conversion (`ShapeInflater`) extracts a single contour from all
strokes (largest Vision contour, or greedy stroke chaining as fallback) and inflates
it with one global spherical profile. This works for simple closed shapes (circles,
triangles) but fails for figures built from **several separate strokes** — a circle
head, an oval body, sausage limbs — which is how users actually draw people and
animals. All but the largest contour is discarded, so multi-stroke figures produce
garbage or lose most of their parts. Additionally, a single global `maxDist` gives
every region the same puff, so even when a compound silhouette survives, thin and
fat parts don't read as distinct volumes.

## Approach (chosen)

**Per-part inflation with union in the depth field.** The inflater already computes
a scalar depth field over a 2D grid and meshes it; "multiple simple shapes joined
together" therefore needs no 3D booleans/CSG. Each closed stroke becomes a *part*,
each part is inflated independently with its own `maxDist`, and the per-cell depths
are combined with a smooth-max. The combined grid feeds the existing mesh builder
unchanged.

Alternatives considered and rejected for v1:

- **Full primitive fitting + 3D mesh assembly** (per the 2026-03-13 spec):
  classify parts as ellipse/rectangle/capsule, instantiate parametric primitives,
  CSG-union them. Rejected: mesh union is hard, and intersecting shells break the
  single-sheet assumptions baked into StrokeLifter, in-place deform, and BVH
  picking. The part contours produced by this design are exactly the input that
  pipeline would need, so it can be layered on later.
- **Silhouette repair only** (fill + morphological close + union outline, inflate
  as one shape): smallest change, stops outright failures, but keeps the uniform
  "gingerbread cookie" puff. Doesn't deliver compound volumes.

## Design

### 1. Part extraction — new `PartExtractor`

Runs before inflation on the object's stroke cluster (strokes are already
resampled to uniform 2 pt spacing by `StrokeConverter`).

For each stroke:

- **Closure test:** the stroke is a part iff
  `distance(first, last) ≤ partClosureRatio × arcLength` (default ratio 0.2).
  Parts are snap-closed by connecting last→first.
- **Degenerate filter:** rejected as a part if the closed loop has < 3 points or
  `|signedArea| < partMinArea` (default 100 pt²; catches back-and-forth scribbles
  that technically "close").
- **Cleanup:** `partSmoothingPasses` (default 2) of wrap-around Laplacian
  smoothing on the loop, then Douglas–Peucker simplification if the loop exceeds
  the existing `contourMaxPoints` cap. No Vision call on this path — the stroke
  polyline is the contour.

Output type: `Part { contour: [CGPoint], sourceStrokeID: Stroke.ID }` — a small
standalone value, kept public within the module because it is the natural input
for future primitive fitting / part-level editing.

**Open and degenerate strokes** contribute no volume. They remain in
`sourceStrokeIDs` and lift onto the surface as decoration via the existing
StrokeLifter path, the same way interior detail ink behaves today.

**Fallback:** if extraction yields **zero** parts (e.g. an outline sketched from
several open arcs), the entire drawing goes through today's Vision single-contour
path unchanged. A drawing with one closed stroke behaves near-identically to
today (modulo loop smoothing).

### 2. Multi-part inflation — changes inside `ShapeInflater.inflate`

Grid setup is unchanged: padded bbox of **all** strokes, adaptive spacing capped
at ~150 cells per axis, per-row `DispatchQueue.concurrentPerform`.

- **Per-part distance:** the parallel pass evaluates `containsAndDistance` per
  part, producing one distance buffer per part. Per-cell cost is
  total-edges-across-parts — the same order as today's single contour of equal
  total point count.
- **Per-part profile:** each part gets its own `maxDist_i` (max distance over the
  cells it contains), and `depth_i = sqrt(d_i · (2·maxDist_i − d_i))`. This is
  the source of distinct volumes: a head puffs to head radius, a limb to limb
  radius, instead of one global `maxDist` flattening everything.
- **Union by smooth-max:** per cell, combine only the parts that contain it:
  - inside exactly one part → that part's depth directly;
  - inside several → polynomial smooth-max with blend width `partBlendRadius`
    (default 10 pt world units; 0 degrades to hard max). Formula (smooth-max is
    the mirrored SDF smooth-min):
    `h = clamp(0.5 + 0.5·(b−a)/k, 0, 1); result = mix(a, b, h) + k·h·(1−h)`,
    folded left over the containing parts' depths.
  - Blending applies only where memberships overlap; a slight C0 crease along the
    overlap boundary curve is accepted (seam subdivision + gradient normals keep
    it visually smooth). `partBlendRadius` is the tuning knob.
- The combined depth grid feeds the **unchanged** `buildMesh` and
  `subdivideElongatedEdges`. Output remains one welded front/back sheet with the
  established −z winding convention.

### 3. Integration and data model

No changes to `Mesh`, `SculptObject`, `MeshBVH`, `SculptRenderer`, or
`StrokeLifter`. `ShapeInflater.sculpt(from:config:)` keeps its signature;
`originRect` stays the bbox of all source stroke points. Call sites
(`SculptScreen.swift`, `Edit25DOverlay.swift`) are untouched. Part contours are
computed and discarded after meshing in v1.

### 4. Config additions (`SculptConfig`)

| Key | Default | Meaning |
| --- | --- | --- |
| `partClosureRatio` | `0.2` | endpoint gap ≤ ratio × arc length → stroke is a closed part |
| `partMinArea` | `100` | minimum \|signed area\| (pt²) for a loop to count as a part |
| `partSmoothingPasses` | `2` | Laplacian smoothing passes per part loop |
| `partBlendRadius` | `10` | smooth-max blend width in world pt; 0 = hard max |

All existing knobs keep their meaning.

### 5. Edge cases and error handling

- **Disjoint parts** (drawn not touching): the grid yields separate shells in one
  mesh; boundary welding is local, so this works — one object, several blobs.
- **Part fully inside another** (belly circle on a torso): smooth-max adds volume
  only where the inner part exceeds the host — a natural bump. Covered by a test.
- **Self-intersecting "closed" loop** (figure-8): even-odd containment inflates
  both lobes. Accepted, not special-cased.
- **All parts degenerate / none close:** fallback to the existing single-contour
  Vision path (§1 fallback).
- **Known v1 limitation:** a body part outlined with multiple open arcs does not
  become a part (its strokes fall to decoration) unless *no* stroke in the object
  closes, in which case the whole-drawing fallback still applies. Documented,
  deferred.
- **Decoration ink far outside the volume** may fail StrokeLifter's tolerance
  ring search and not lift. Existing behavior is pinned by a test; improving lift
  reach is out of scope.

### 6. Testing

Unit tests:

- Closure detection: closed circle stroke, open line, nearly-closed arc (gap just
  under/over threshold), zero-area back-and-forth scribble.
- Laplacian smoothing preserves closure and point count.
- Per-part `maxDist` independence: snowman fixture — head region shallower than
  body region.
- Watertightness of the blended mesh at joints (reuse `MeshTests` checks).
- Open strokes contribute zero volume (mesh identical with/without an open
  decoration stroke).
- Part-inside-part produces a bump, not a crater.
- Fallback regression: all existing `MeshTests`, `PipelineDiagnosticTests`,
  `InferencePipelineTests`, `StrokeConverterTests` pass unmodified.

Visual/pipeline: add a person/snowman multi-stroke fixture to
`PipelineVisualTests`.

## Out of scope (v1)

- Primitive classification/beautification (ellipse/capsule fitting) — the `Part`
  type is the seam for it.
- Part-level editing (select/move a part after creation).
- Merging multiple open arcs into one part contour.
- CSG/mesh-boolean assembly of parametric primitives.
