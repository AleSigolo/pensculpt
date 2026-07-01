# 2.5D Edit Mode — Design

**Date:** 2026-07-02
**Status:** Draft, pending user review
**Area:** Stage 2 → Integration (supersedes the modal Sculpt hand-off)

## Summary

A unified **2.5D edit mode** that replaces the modal `SculptScreen` hand-off.
The user selects a shape (lasso or smart selector) and the selection **lifts
off the page in place**: the inferred mesh appears exactly where the ink was,
with the original ink mapped onto its surface, while the rest of the drawing
stays visible around it. The user can then, without any further mode switch:

- **draw** with the pencil — on the shape (ink lands on the surface and
  rotates with it) or beside it (normal 2D ink on the canvas),
- **rotate** the shape with fingers (or thumb-button + pen),
- **distort** it with the deform/smooth brush (drawn ink deforms with it).

Tapping away (or a Done button) **bakes** the shape back to 2D at its current
orientation: what you see is what stays on the canvas. Re-selecting the baked
ink re-enters the edit session with the mesh and orientation intact.

The core interaction rule, from the original design spec (§136–138):
**fingers manipulate, the pen draws.** No tool switching is needed for the
primary loop of rotate-a-bit, draw-a-bit.

## Goals

- Eliminate the modal seam: sculpting happens *in place* on the drawing, with
  the surrounding 2D canvas visible and drawable throughout.
- Visually seamless entry: at the moment of lift-off, the mesh's projection is
  pixel-registered with the 2D ink it was inferred from (identity rotation,
  orthographic camera, no camera tilt).
- Ink is first-class: source strokes ride on the mesh, new surface strokes are
  black ink (not the current debug blue), and the mesh itself renders as a
  subtle paper-toned ghost so the aesthetic stays "drawing", not "3D viewer".
- Baking is true 2.5D: on exit, **all** surface ink is projected to 2D through
  the *current* rotation, replacing the hidden originals — rotating a shape
  visibly rotates its drawing.
- Round-trippable: `SculptObject` persists its orientation/scale so a baked
  shape can be re-lifted and edited again.
- Reuse the existing primitives: `ShapeInflater`, `hitTest`/BVH picking,
  `SurfaceStroke.reprojected`, arcball rotation, deform brush (which already
  carries surface strokes with the mesh).

## Non-goals (YAGNI)

- Multiple objects lifted simultaneously — one active object per edit session.
- PKCanvasView zoom/scroll support while in edit mode (canvas is 1:1 today;
  the camera registration assumes that and asserts it).
- Perspective camera (tracked separately in TODO).
- Deformation surviving *re-inference* (the existing gap — deforms are baked
  into vertices; unchanged by this feature).
- Occlusion of the shape by surrounding 2D ink (the lifted shape always
  renders above the canvas).
- Editing stroke color; ink is black, matching Stage 1.

## Decisions (resolved during design)

| Question | Decision |
|----------|----------|
| Architecture | **In-place overlay**: transparent `MTKView` layered above the live (frozen) `PKCanvasView` inside `DrawingScreen`'s ZStack. PencilKit stays the 2D engine. |
| Mode model | `AppMode` gains `.edit`. Flow: `.draw` ↔ `.select` → (commit selection) → `.edit` → (bake) → `.draw`. The `fullScreenCover`/`SculptScreen` is removed. |
| Entry trigger | Committing a selection (lasso close / smart-grow release) lifts the shape directly — no separate "Sculpt" button press. Inference runs async; ink lifts with a ghost placeholder until the mesh arrives. |
| Registration | New `CameraTransform` utility: orthographic projection mapping world ↔ canvas points 1:1 across the whole view; model transform = `T(center) · R(orientation) · S(scale) · T(−center)` pivoting at the object's world center. Replaces the object-fit `combinedBounds` camera. |
| Source ink on entry | Source strokes are ray-cast along (0,0,−1) onto the mesh into `SurfaceStroke`s (reusing the `reprojected` machinery) and hidden from the PK canvas for the session. |
| Input routing | Pen on mesh → surface stroke. Pen off mesh → normal 2D stroke (raw-touch capture → `Stroke` + `PKStroke`). One finger drag → arcball rotate. Two-finger pinch → object scale; two-finger twist → roll. Thumb button held + pen → rotate. Deform/smooth toggles → pen deforms. One-finger tap off mesh → commit & exit. |
| Exit bake | Project every surface stroke through the current model transform, drop depth, y-flip back to canvas space → new 2D `Stroke`s + `PKStroke`s. Originals are deleted; `sourceStrokeIDs` is updated to the baked stroke IDs so re-selection finds the object. |
| Persistence | `SculptObject` gains `orientation: simd_quatf` and `scale: Float` (Codable with defaults for migration). Surface strokes gain a color (default black). |
| Mesh look | Shaded ghost: near-paper albedo with soft Lambert shading and the existing light; `displayMode` default flips from `"wireframe"` (debug artifact) to `"shaded"`. |
| Undo | Surface-stroke add and deform gestures register with `UndoManager` (deform undo = pre-gesture vertex snapshot). Rotation/scale are not undoable — they're directly reversible by hand. |

## Approaches considered

1. **In-place overlay (chosen).** Transparent Metal layer over the live
   PencilKit canvas. Keeps PencilKit's ink quality and the entire Stage 1
   pipeline; the Metal renderer only ever draws the active object. Cost:
   careful camera registration and a raw-touch path for off-mesh pen strokes.
2. **Enhanced modal.** Keep `SculptScreen` but render a canvas snapshot as a
   backdrop texture and open with a cross-fade. Much cheaper, but the canvas
   is a dead image — no drawing beside the shape, and the modal seam remains.
   Rejected: fails the "seamless" requirement.
3. **Full Metal unification.** Replace PencilKit; one renderer, one input
   pipeline. Cleanest end-state but forfeits PencilKit's predictive stroke
   rendering and hover preview, and rewrites all of Stage 1. Rejected as a
   rewrite disguised as a feature.

## Architecture

### Components

- **`AppMode.edit`** (`Models/AppMode.swift`) — new case; `DrawingViewModel`
  owns the transition and the active `SculptObject` ID.
- **`Edit25DOverlay`** (new, `Views/`) — SwiftUI view embedded in
  `DrawingScreen`'s ZStack when mode is `.edit`. Hosts the transparent
  `MetalCanvasView` plus the compact tool HUD (thumb-rotate, deform, smooth,
  brush size, re-infer, done). Absorbs `SculptScreen`'s responsibilities;
  `SculptScreen` and the `fullScreenCover` are deleted.
- **`CameraTransform`** (new, `Rendering/`) — pure struct owning
  projection/view/model matrices, world↔canvas↔screen conversions, and
  unprojection. Replaces the three duplicated unproject blocks in
  `SculptRenderer` (`hitTest`, `deformMesh`, `smoothMesh`).
- **`EditInputRouter`** (new, `Rendering/` or `Views/`) — pure, testable
  classifier: `(touchType, hitTestResult, thumbButton, activeTool) →
  EditAction` (drawOnSurface / drawOnCanvas / rotate / deform / smooth /
  commit). The `MetalCanvasView.Coordinator` becomes a thin adapter over it.
- **`StrokeLifter`** (new, `Inference/` or `Models/`) — pure functions for the
  two projections: `lift(strokes, onto: mesh) -> [SurfaceStroke]` (entry) and
  `bake(surfaceStrokes, transform) -> [Stroke]` (exit). Both are
  deterministic and unit-testable; identity-rotation bake of lifted strokes
  must round-trip to the original point positions within tolerance.
- **`SculptObject`** — gains `orientation`, `scale`, and per-surface-stroke
  color, all with decoding defaults so existing documents load.

### Data flow

**Entry** (selection committed):
1. `DrawingViewModel` resolves the selection → existing object (by
   `sourceStrokeIDs` overlap, as today) or kicks off `ShapeInflater` async.
2. Source `PKStroke`s are removed from `pkDrawing` (kept in `canvas.strokes`,
   flagged hidden for the session); the overlay fades in.
3. When the mesh is ready, `StrokeLifter.lift` maps source strokes onto it;
   renderer shows ghost mesh + ink, pixel-registered at identity orientation.
   On **re-entry** no lift is needed: the object already carries its surface
   strokes and persisted orientation, and the baked 2D ink was produced by
   projecting exactly that state — so hiding the baked ink and rendering the
   object is registered by construction.

**During edit:** touches → `EditInputRouter` → existing handlers
(`handleDraw`, `applyRotation`, `handleDeform`) or the new off-mesh 2D stroke
capture (coalesced raw touches → `Stroke` → append to canvas + `pkDrawing`).
Off-mesh strokes are ordinary canvas ink and do not join the object.

**Exit** (tap-away or Done):
1. `StrokeLifter.bake` projects all surface strokes through the current model
   transform to 2D strokes.
2. Original source strokes are deleted from `canvas` (undoably); baked strokes
   are inserted into `canvas` and `pkDrawing`; `sourceStrokeIDs` ← baked IDs;
   `orientation`/`scale` persist on the object.
3. Overlay fades out; mode → `.draw`.

### Error handling

- **Inference fails / empty contour:** overlay dismisses with a brief toast;
  selection and ink are restored untouched.
- **Hit-test t-jump mid-stroke:** existing `surfaceStrokeMaxTJump` splitting
  behavior is kept.
- **Bake with zero surface strokes** (user deleted everything): originals are
  simply removed; object is discarded.
- **Vertex-count mismatch on re-infer morph:** existing hard-replace fallback.

### Testing

Pure-logic units, one test file per source file per convention:
`CameraTransform` (world↔canvas registration invariants, unproject vs the old
inline math), `StrokeLifter` (lift/bake round-trip at identity; 90° rotation
bake produces expected profile), `EditInputRouter` (full classification
table), `SculptObject` codable migration (old JSON without
orientation/scale/color decodes), plus the existing renderer/deform tests
staying green. Interaction feel (lift animation, haptics, gesture
disambiguation) is verified manually on device.

## Open questions for review

- **Entry trigger:** this design lifts the shape immediately on selection
  commit, replacing the "Sculpt" capsule button. If accidental lifts feel bad
  in practice, the button comes back as a confirm step — cheap to change.
- **Pinch = object scale** (bakes into the drawing's size) vs pinch = camera
  zoom (temporary). Object scale chosen because it matches "distorting it".
- **Single-finger drag = rotate** is powerful but may collide with future
  canvas panning. Acceptable while edit mode is active-object-scoped.
