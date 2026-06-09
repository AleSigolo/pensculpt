# PenSculpt TODO

Status legend:
- `[ ]` Not started
- `[x]` Completed
- Optimization: `O[ ]` Not optimized / `O[x]` Code optimized
- Simplification: `S[ ]` Not simplified / `S[x]` Code simplified

---

## Stage 1: Drawing Engine

- [x] Project setup (Xcode project, targets, UTI) — O[ ] S[ ]
- [x] StrokePoint model (position, pressure, tilt, azimuth, timestamp) — O[ ] S[ ]
- [x] Stroke model (points, color, bounding box, Codable) — O[x] S[ ]
- [x] Canvas model (stroke management, Codable) — O[x] S[ ]
- [x] StrokeConverter (PKStroke to internal Stroke) — O[ ] S[ ]
- [x] CanvasView (PKCanvasView UIViewRepresentable wrapper) — O[x] S[ ]
- [x] FloatingToolbar (undo, redo, eraser, clear) — O[ ] S[x]
- [x] DrawingScreen (full-screen canvas with toolbar button) — O[x] S[x]
- [x] PenSculptDocument (ReferenceFileDocument, .pensculpt package format) — O[ ] S[ ]
- [x] App entry point (DocumentGroup wiring) — O[ ] S[ ]
- [x] Undo/Redo (UndoManager registration for add/remove/clear) — O[ ] S[ ]
- [x] Unit tests (StrokePoint, Stroke, Canvas, StrokeConverter, Document) — O[ ] S[ ]
- [x] Drawing basics guide — O[ ] S[ ]
- [x] Apple Pencil double-tap toggle (pen/eraser) — O[ ] S[ ]
- [x] Apple Pencil hover cursor preview (provided by PencilKit) — O[x] S[x]

## Stage 2: Sculpt Mode

### Selection System
- [x] SelectionStrategy (lasso/smart kinds + unified SelectionOverlay) — O[ ] S[ ]
- [x] StrokeGroup model — O[ ] S[ ]
- [x] LassoSelection (point-in-polygon, 50% threshold) — O[ ] S[ ]
- [x] Selection UI (mode toggle, lasso overlay, highlights) — O[ ] S[x]
- [x] StrokeClustering (union-find, ink proximity) — O[ ] S[ ]  <!-- O[ ]: O(n²) pair scan; spatial grid TODO -->
- [x] SmartSelection (reach-based, seed-at-nearest, monotonic) — O[ ] S[ ]
- [x] Smart selector gesture (hold-to-grow, ring + haptics) — O[ ] S[ ]
- [x] Selection strategy toggle (Lasso/Smart, long-press auto-switch) — O[ ] S[ ]

### Inference Pipeline
- [x] ContourExtractor (Vision ML contour detection with fallback) — O[ ] S[ ]
- [x] ShapeInflater (grid distance field → sphere-like depth → front/back mesh) — O[x] S[x]
- [x] SculptObject model — O[ ] S[ ]
- [x] SculptConfig (gridSpacing, cameraTilt, contour params, displayMode) — O[ ] S[ ]

### Metal Renderer
- [x] MetalCanvasView (MTKView, orthographic camera) — O[ ] S[ ]
- [x] Mesh rendering (diffuse lighting, wireframe debug mode) — O[x] S[ ]
- [x] Stroke rendering (triangle strips, pressure-based width) — O[ ] S[ ]
- [ ] Stroke style toggle (screen-space vs surface-space) — O[ ] S[ ]
- [x] Metal shaders (vertex + fragment) — O[ ] S[ ]

### Sculpt Interaction
- [x] Rotation (two-finger drag, arcball) — O[ ] S[ ]
- [x] Draw-on-surface (ray cast, bake at viewing angle) — O[ ] S[ ]
- [x] Thumb button for pen-rotate mode — O[ ] S[ ]
- [x] Mesh deformation (soft brush, Gaussian falloff) — O[ ] S[ ]
- [x] Re-inference (async, correction preservation, cross-fade) — O[ ] S[ ]

### Integration
- [x] SculptScreen view — O[ ] S[ ]
- [x] Mode switching (Draw → Select → Sculpt) — O[ ] S[x]
- [x] Multi-object interaction (active/dimmed) — O[ ] S[ ]
- [x] Document persistence for SculptObjects — O[ ] S[ ]
- [ ] Sculpt mode guide — O[ ] S[ ]

## Future Stages
- [x] Project surface strokes back to 2D canvas — O[ ] S[ ]
- [ ] Color picker and color strokes — O[ ] S[ ]
- [ ] Grow selection (tap + hold duration) — O[ ] S[ ]
- [ ] Export (image, OBJ/USDZ, share sheet) — O[ ] S[ ]
- [ ] Perspective camera toggle — O[ ] S[ ]
- [ ] Advanced inference pipeline (SkeletonExtractor, Segmenter, PrimitiveFitter, MeshAssembler, StrokeMapper) — O[ ] S[ ]
