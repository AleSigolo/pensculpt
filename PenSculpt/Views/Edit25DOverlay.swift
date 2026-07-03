import SwiftUI
import simd

/// In-place 2.5D edit session hosted inside DrawingScreen's ZStack.
/// Owns inference-on-entry, ink lift, the tool HUD, and commit.
struct Edit25DOverlay: View {
    var sourceStrokes: [Stroke]
    @Binding var sculptObjects: [SculptObject]
    var config: SculptConfig = .default
    /// Called with the edited object's ID and the baked 2D strokes.
    var onCommit: (UUID, [Stroke]) -> Void
    /// A flat stroke drawn beside the shape during the session.
    var onCanvasStroke: (Stroke) -> Void
    /// Inference produced no usable mesh — abandon the session.
    var onInferenceFailed: () -> Void
    /// The session's object was removed out from under it (an undo restored
    /// external state wholesale). The host must tear the session down WITHOUT
    /// re-inserting hidden ink — the undo already restored a consistent
    /// canvas/pkDrawing pair.
    var onSessionInvalidated: () -> Void
    /// Reports how the session resolved the source strokes, in the same
    /// main-actor turn the mesh mounts: `hidden` is the ink now riding the
    /// mesh (the host removes its PK strokes so the mesh replaces it
    /// visually — on a re-entry this covers the WHOLE object, which can be
    /// wider than the selection), and `unlifted` is flat ink that stays
    /// visible and survives commit untouched (never-lifted strokes plus
    /// selected strokes that don't belong to the object).
    var onSourceStrokesResolved: (_ hidden: Set<UUID>, _ unlifted: Set<UUID>) -> Void

    @State private var activeObjectID: UUID?
    @State private var isRotateMode = false
    @State private var isDeformMode = false
    @State private var isSmoothMode = false
    @State private var isEraseStrokeMode = false
    @State private var brushSize: CGFloat = 8
    @State private var brushOpacity: CGFloat = 1
    @State private var savedDrawOpacity: CGFloat = 1
    @State private var deformCursor: (position: CGPoint, radius: CGFloat)?
    @State private var isInferring = false
    @State private var showFullSculpt = false
    @State private var sessionOrientation = simd_quatf(vector: SIMD4(0, 0, 0, 1))
    @State private var sessionScale: Float = 1
    @State private var rendererReplaceMesh: ((UUID, Mesh, [SurfaceStroke]?) -> Void)?
    @State private var rendererCacheBVH: ((UUID, MeshBVH) -> Void)?
    @State private var inferenceTask: Task<Void, Never>?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ZStack {
            if let objectID = activeObjectID,
               let obj = sculptObjects.first(where: { $0.id == objectID }) {
                MetalCanvasView(
                    sculptObjects: sculptObjects,
                    activeObjectID: objectID,
                    config: config,
                    isRotateMode: isRotateMode,
                    isDeformMode: isDeformMode,
                    isSmoothMode: isSmoothMode,
                    isEraseStrokeMode: isEraseStrokeMode,
                    brushSize: Float(brushSize),
                    brushOpacity: Float(brushOpacity),
                    onSurfaceStrokeCompleted: handleSurfaceStroke,
                    onMeshDeformed: handleMeshDeformed,
                    onDeformCursor: { deformCursor = $0 },
                    onRendererReady: { replace, _, cacheBVH in
                        Task { @MainActor in
                            rendererReplaceMesh = replace
                            rendererCacheBVH = cacheBVH
                        }
                    },
                    editSession: .init(objectID: objectID,
                                       pivot: pivot(for: obj),
                                       initialOrientation: obj.orientation,
                                       initialScale: obj.scale),
                    onCanvasStrokeCompleted: onCanvasStroke,
                    onEditTransformChanged: { q, s in
                        sessionOrientation = q
                        sessionScale = s
                    },
                    onCommitRequested: commit
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if isInferring {
                ProgressView("Lifting…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay {
            if let cursor = deformCursor {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: config.deformCursorLineWidth,
                                                     dash: config.deformCursorDash))
                    .foregroundStyle(.orange.opacity(config.deformCursorOpacity))
                    .frame(width: cursor.radius * 2, height: cursor.radius * 2)
                    .position(cursor.position)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12) {
                Button {
                    // The post-commit window (activeObjectID latched to nil)
                    // must never present the workspace for a finished session.
                    guard activeObjectID != nil else { return }
                    showFullSculpt = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .disabled(activeObjectID == nil)

                Button(action: commit) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                }
                .disabled(activeObjectID == nil)
            }
            .padding()
        }
        .overlay(alignment: .bottom) {
            BrushControls(brushSize: $brushSize, brushOpacity: $brushOpacity,
                          isDeformMode: isDeformMode)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 20)
        }
        .overlay(alignment: .bottomLeading) {
            Image(systemName: isRotateMode ? "rotate.3d.fill" : "rotate.3d")
                .font(.title)
                .foregroundStyle(isRotateMode ? .blue : .secondary)
                .frame(width: 60, height: 60)
                .background(.ultraThinMaterial, in: Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isRotateMode = true }
                        .onEnded { _ in isRotateMode = false }
                )
                .padding(20)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 12) {
                Button {
                    if isDeformMode { isSmoothMode.toggle() } else { isEraseStrokeMode.toggle() }
                } label: {
                    let active = isDeformMode ? isSmoothMode : isEraseStrokeMode
                    Image(systemName: active ? "eraser.fill" : "eraser")
                        .font(.title2)
                        .foregroundStyle(active ? .mint : .secondary)
                        .frame(width: 50, height: 50)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    if isDeformMode {
                        isDeformMode = false
                        isSmoothMode = false
                        brushOpacity = savedDrawOpacity
                    } else {
                        savedDrawOpacity = brushOpacity
                        isDeformMode = true
                        isEraseStrokeMode = false
                        brushOpacity = CGFloat(config.deformDefaultForce)
                    }
                } label: {
                    Image(systemName: isDeformMode ? "hand.point.up.fill" : "hand.point.up")
                        .font(.title)
                        .foregroundStyle(isDeformMode ? .orange : .secondary)
                        .frame(width: 60, height: 60)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pencilDoubleTap)) { _ in
            if isDeformMode { isSmoothMode.toggle() } else { isEraseStrokeMode.toggle() }
        }
        .fullScreenCover(isPresented: $showFullSculpt, onDismiss: refreshRendererAfterExpand) {
            if !sourceStrokes.isEmpty {
                SculptScreen(strokes: sourceStrokes, sculptObjects: $sculptObjects)
            }
        }
        .onChange(of: sculptObjects) { _, newObjects in
            // An undo of an earlier commit restores sculptObjects wholesale and
            // can delete this session's object out from under it. The undo also
            // restored canvas/pkDrawing as a consistent pair, so the host must
            // tear down WITHOUT re-inserting the session's hidden ink (the
            // cancel path would duplicate it) — hence not onInferenceFailed().
            guard let id = activeObjectID, !isInferring,
                  !newObjects.contains(where: { $0.id == id }) else { return }
            onSessionInvalidated()
        }
        .onAppear(perform: startSession)
        .onDisappear { inferenceTask?.cancel() }
    }

    // MARK: - Session lifecycle

    private func pivot(for obj: SculptObject) -> SIMD3<Float> {
        SIMD3(Float(obj.originRect.midX), -Float(obj.originRect.midY), 0)
    }

    /// Resolves a selection to an existing sculpt object by sourceStrokeIDs
    /// OVERLAP (per the design spec), not exact set equality: real
    /// re-selections routinely differ by a stroke or two (the smart selector
    /// clusters by proximity, a lasso grabs a doodle beside the shape), and
    /// demanding equality silently downgraded almost every re-entry to a
    /// fresh lift — re-inferring from already-baked ink and compounding
    /// degradation on every rotate→bake→re-select cycle. Ties resolve to the
    /// largest overlap, then the most recent object (stable for equal ids).
    nonisolated static func resolveSessionObject(selection: Set<UUID>,
                                                 objects: [SculptObject]) -> SculptObject? {
        objects.enumerated()
            .map { (index: $0, object: $1,
                    overlap: $1.sourceStrokeIDs.intersection(selection).count) }
            .filter { $0.overlap > 0 }
            .max { ($0.overlap, $0.index) < ($1.overlap, $1.index) }?
            .object
    }

    private func startSession() {
        // Idempotent: a spurious double onAppear must never double-infer
        // or double-append.
        guard activeObjectID == nil, !isInferring else { return }
        let strokeIDs = Set(sourceStrokes.map(\.id))

        if let match = Self.resolveSessionObject(selection: strokeIDs,
                                                 objects: sculptObjects) {
            // Re-entry: the object already carries its surface ink and
            // persisted orientation; the baked 2D ink was produced from exactly
            // that state, so rendering it is registered by construction.
            sessionOrientation = match.orientation
            sessionScale = match.scale
            activeObjectID = match.id
            // Hide the object's whole lifted ink (even ink the selection
            // missed — commit rebakes all of it, so leaving it visible would
            // desync the stores). Keep visible: strokes that never lifted
            // (persisted on the object) AND selected strokes that don't
            // belong to the object — both stay ordinary flat ink and carry
            // through commit untouched (commit also folds them into the
            // object's next identity, so selecting the same group again
            // re-enters even more reliably).
            onSourceStrokesResolved(
                match.sourceStrokeIDs.subtracting(match.unliftedStrokeIDs),
                match.unliftedStrokeIDs.union(strokeIDs.subtracting(match.sourceStrokeIDs))
            )
            return
        }

        // Fresh lift: infer, then move the source ink onto the mesh.
        isInferring = true
        let strokes = sourceStrokes
        let cfg = config
        inferenceTask = Task.detached {
            let obj = ShapeInflater.sculpt(from: strokes, config: cfg)
            guard !obj.mesh.isEmpty else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isInferring = false
                    onInferenceFailed()
                }
                return
            }
            let bvh = MeshBVH(mesh: obj.mesh)
            let lift = StrokeLifter.lift(strokes, bvh: bvh,
                                         offset: cfg.surfaceStrokeOffset)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                var newObj = obj
                newObj.surfaceStrokes = lift.lifted
                newObj.unliftedStrokeIDs = lift.unliftedStrokeIDs
                sculptObjects.append(newObj)
                activeObjectID = newObj.id
                sessionOrientation = newObj.orientation
                sessionScale = newObj.scale
                // No rendererCacheBVH call here: the MetalCanvasView (and its
                // renderer) mounts only AFTER activeObjectID is set above, so
                // the callback is still nil at this point. The renderer's
                // sculptObjects didSet -> prebuildBVHs() builds the BVH
                // asynchronously on mount instead.
                isInferring = false
                onSourceStrokesResolved(strokeIDs.subtracting(lift.unliftedStrokeIDs),
                                        lift.unliftedStrokeIDs)
            }
        }
    }

    /// The expanded workspace ran its own renderer on the shared model;
    /// deforms or re-infers made there leave this overlay's renderer holding a
    /// stale vertex buffer and BVH for the session object. Re-push the mesh
    /// (replaceMesh clears both caches for the id) and rebuild the BVH.
    private func refreshRendererAfterExpand() {
        guard let objectID = activeObjectID,
              let obj = sculptObjects.first(where: { $0.id == objectID }) else { return }
        pushObjectToRenderer(obj)
    }

    /// Force-push an object's mesh + surface ink into the overlay's renderer
    /// and rebuild its BVH off-main. Needed whenever the model changed under
    /// an id the renderer already caches (expand-workspace edits, deform
    /// undo): the renderer's sculptObjects didSet only prunes caches for
    /// REMOVED ids, so a changed mesh behind an existing id stays stale.
    private func pushObjectToRenderer(_ obj: SculptObject) {
        rendererReplaceMesh?(obj.id, obj.mesh, obj.surfaceStrokes)
        let id = obj.id
        let mesh = obj.mesh
        Task.detached {
            let bvh = MeshBVH(mesh: mesh)
            await MainActor.run {
                rendererCacheBVH?(id, bvh)
            }
        }
    }

    private func commit() {
        guard let objectID = activeObjectID,
              let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        var obj = sculptObjects[idx]
        obj.orientation = sessionOrientation
        obj.scale = sessionScale
        sculptObjects[idx] = obj

        let baked = StrokeLifter.bake(obj.surfaceStrokes,
                                      orientation: sessionOrientation,
                                      scale: sessionScale,
                                      pivot: pivot(for: obj))
        onCommit(objectID, baked)
        // Latch: disable the checkmark, unmount the MetalCanvasView (killing
        // the tap-to-commit path), and fail the guard above on any re-entry —
        // a double-tap during the exit fade must never commit twice.
        activeObjectID = nil
    }

    private func handleSurfaceStroke(_ stroke: SurfaceStroke) {
        guard let objectID = activeObjectID,
              let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        sculptObjects[idx].surfaceStrokes.append(stroke)
        undoManager?.registerUndo(withTarget: EditUndoProxy.shared) { _ in
            // No-op gracefully if the object (or the stroke) is already gone,
            // e.g. an earlier commit's undo restored sculptObjects wholesale.
            guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
            sculptObjects[idx].surfaceStrokes.removeAll { $0.id == stroke.id }
            // Mesh unchanged: the renderer re-reads surface strokes from the
            // binding via updateUIView, so no cache invalidation is needed.
        }
    }

    private func handleMeshDeformed(_ objectID: UUID, _ mesh: Mesh, _ surfaceStrokes: [SurfaceStroke]) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        // The renderer mutated its own copy during the gesture (updateUIView's
        // binding→renderer sync is blocked while deforming), so the binding
        // still holds the PRE-gesture object here — snapshot it for undo
        // before writing. Covers deform, smooth, and stroke-erase (all arrive
        // via onMeshDeformed). One-way undo (no redo), matching app style.
        let before = sculptObjects[idx]
        sculptObjects[idx].mesh = mesh
        sculptObjects[idx].surfaceStrokes = surfaceStrokes
        undoManager?.registerUndo(withTarget: EditUndoProxy.shared) { _ in
            guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
            sculptObjects[idx].mesh = before.mesh
            sculptObjects[idx].surfaceStrokes = before.surfaceStrokes
            // The renderer picks the restored model up via updateUIView, but
            // its sculptObjects didSet only prunes caches for REMOVED ids —
            // an old mesh behind an existing id would keep a stale vertex
            // buffer and BVH (same class of bug as the expand refresh).
            pushObjectToRenderer(sculptObjects[idx])
        }
    }
}

/// UndoManager requires a class target for closure-based registration and
/// SwiftUI views aren't objects, so registrations use this shared inert token
/// (same pattern as DrawingScreen's private UndoProxy).
private final class EditUndoProxy {
    static let shared = EditUndoProxy()
}
