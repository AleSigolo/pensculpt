# PenSculpt — Agent Instructions

## Project Overview

PenSculpt is an iPad drawing app for Apple Pencil that lets users draw in 2D and then "sculpt" their drawings into pseudo-3D objects. Development is staged:

- **Stage 1** (implemented): Black-and-white drawing with PencilKit, save/load, undo/redo, eraser
- **Stage 2** (next): Lasso selection, 3D shape inference from 2D strokes, custom Metal renderer, rotate-and-draw workflow

## Key Documents

- **Design spec:** `docs/superpowers/specs/2026-03-13-pensculpt-design.md` — full architecture and requirements
- **Implementation plan:** `docs/superpowers/plans/2026-03-13-pensculpt-stage1.md` — task-by-task plan with code
- **TODO tracking:** `TODO.md` — all features with completed/optimized/simplified status
- **Feature guides:** `guides/` — human-readable documentation per feature

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Drawing engine | PencilKit | Mature Apple Pencil support out of the box |
| 3D renderer | Custom Metal | Pixel-level control for stroke-on-surface rendering |
| 3D framework | None (custom) | SceneKit/RealityKit don't give enough stroke rendering control |
| Document model | ReferenceFileDocument | Pairs with UndoManager, supports incremental saves |
| File format | .pensculpt package | JSON strokes + binary mesh data + thumbnail |
| Camera | Orthographic (default) | Matches flat drawing aesthetic when entering sculpt mode |
| Selection | SelectionStrategy marker protocol | Lasso + Grow strategies coexist via concrete static APIs; protocol documents the family |

## Project Structure

```
PenSculpt/
├── App/           — App entry point, DocumentGroup scene
├── Models/        — Stroke, StrokePoint, Canvas, SculptObject
├── Drawing/       — PencilKit integration (CanvasView, StrokeConverter)
│   └── Selection/ — SelectionStrategy protocol, LassoStrategy, GrowStrategy
├── Views/         — SwiftUI views (DrawingScreen, FloatingToolbar)
├── Inference/     — 3D shape inference pipeline (contour, skeleton, fitting, assembly)
├── Renderer/      — Custom Metal renderer (mesh, strokes, shaders)
├── Persistence/   — PenSculptDocument, file format handling
├── Resources/     — Info.plist, Metal shader files, assets
```

## Build & Test

```bash
# Generate Xcode project (requires xcodegen)
xcodegen generate

# Build
xcodebuild -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build

# Test
xcodebuild test -project PenSculpt.xcodeproj -scheme PenSculpt \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'
```

## Conventions

- **Swift 5.9**, targeting **iOS 17.0**, **iPad only**
- All models are `Codable`, `Equatable`, `Sendable`
- Internal stroke model (`Stroke`) is canonical — PencilKit strokes are converted on capture
- `Stroke.color` exists but defaults to black (Stage 1); color UI comes in a future stage
- Toolbar is extensible — new tools are added as enum cases in `DrawingTool`
- Tests live in `PenSculptTests/` with one test file per source file
- Feature guides go in `guides/` with numbered prefixes (01-, 02-, etc.)
- After completing a feature, update `TODO.md` status

## Stage 2 Implementation Notes

When implementing Stage 2, follow the plan in `docs/superpowers/plans/2026-03-13-pensculpt-stage1.md` (Chunks 4-7). Key technical details:

1. **Inference pipeline** runs async on a background thread — renderer continues showing previous mesh
2. **Skeleton extraction** uses Zhang-Suen thinning on a 512x512 rasterized bitmap
3. **Primitive fitting** uses circularity (`4*pi*area/perimeter^2`), aspect ratio, and taper ratio thresholds
4. **Mesh assembly** uses implicit surface (metaball) blending + Marching Cubes at 64^3 resolution
5. **Stroke mapping** uses orthographic ray casting from the drawing angle, front-face only
6. **Mesh deformation** uses soft-brush with Gaussian falloff, pen pressure = brush radius
7. **Corrections** are stored as world-space positions (strokes) and displacement vectors (mesh distortions) for re-inference survival
