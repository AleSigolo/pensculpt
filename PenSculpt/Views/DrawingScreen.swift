import SwiftUI
import PencilKit

struct DrawingScreen: View {
    @Binding var documentCanvas: Canvas
    @Binding var drawingData: Data
    @Binding var sculptObjects: [SculptObject]
    @State private var vm: DrawingViewModel
    @State private var pkDrawing = PKDrawing()
    @State private var drawingSyncTask: Task<Void, Never>?
    @State private var viewBridge = ViewBridge()
    @State private var hiddenPKStrokes: [(index: Int, id: UUID, stroke: PKStroke)] = []
    @State private var unliftedSourceIDs: Set<UUID> = []
    @State private var preSessionObjects: [SculptObject] = []
    @State private var showInferenceFailedToast = false
    @Environment(\.undoManager) private var undoManager

    init(canvas: Binding<Canvas>, drawingData: Binding<Data>, sculptObjects: Binding<[SculptObject]>) {
        _documentCanvas = canvas
        _drawingData = drawingData
        _sculptObjects = sculptObjects
        _vm = State(initialValue: DrawingViewModel(canvas: canvas.wrappedValue))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            canvasLayer
            selectionHighlightLayer
            selectModeOverlay
            if vm.appMode == .select { selectStrategyControls }
            if vm.appMode == .draw { drawModeControls }
            if vm.appMode == .edit { editOverlay }
        }
        .overlay(alignment: .top) { savedMessageOverlay }
        .toolbar { navBarItems }
        .onAppear { loadDrawingData() }
        .onChange(of: vm.appMode) { oldMode, newMode in
            if newMode == .edit { beginEditSession() }
        }
        .onChange(of: vm.canvas) { _, _ in
            // Mid-session, canvas.strokes still holds the lifted originals
            // while their PK ink is hidden; persisting one store but not the
            // other would break on-disk positional parity for good. Commit's
            // changes still land: handleEditCommit calls exitEditMode()
            // synchronously, so appMode is already .draw when this fires.
            guard vm.autosaveEnabled, vm.appMode != .edit else { return }
            documentCanvas = vm.canvas
        }
        .onChange(of: pkDrawing) { _, newDrawing in
            guard vm.autosaveEnabled, vm.appMode != .edit else { return }
            debounceSyncDrawing(newDrawing)
        }
        .onChange(of: vm.autosaveEnabled) { _, enabled in
            if enabled { flushToDocument() }
        }
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.black)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var selectionHighlightLayer: some View {
        if vm.appMode == .select && vm.hasSelection {
            SelectionHighlight(strokes: vm.canvas.strokes, selectedIDs: vm.selectedStrokeIDs, viewBridge: viewBridge)
        }
    }

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

    @ViewBuilder
    private var selectStrategyControls: some View {
        SelectionStrategyToggle(strategy: $vm.activeStrategy)
            .padding(.bottom, vm.hasSelection ? 96 : 30)
    }

    @ViewBuilder
    private var savedMessageOverlay: some View {
        // VStack, not bare siblings: both toasts can be visible at once and
        // would otherwise render on top of each other in the .top overlay.
        VStack(spacing: 8) {
            if vm.showSavedMessage {
                Text("Saved!")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showInferenceFailedToast {
                Text("Couldn't lift that selection")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 60)
    }

    private var navBarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                if vm.appMode != .edit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { vm.toggleMode() }
                    } label: {
                        Image(systemName: vm.appMode == .draw ? "lasso" : "pencil.tip")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                }

                Button {
                    withAnimation { vm.autosaveEnabled.toggle() }
                } label: {
                    Image(systemName: vm.autosaveEnabled
                          ? "arrow.triangle.2.circlepath.circle.fill"
                          : "arrow.triangle.2.circlepath.circle")
                        .font(.body)
                        .foregroundStyle(vm.autosaveEnabled ? .primary : .secondary)
                }

                if vm.appMode != .edit {
                    Button { saveToDocument() } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.body)
                    }
                }
            }
        }
    }

    private var canvasLayer: some View {
        CanvasView(
            drawing: $pkDrawing,
            selectedTool: vm.selectedTool,
            strokeWidth: vm.strokeWidth,
            strokeOpacity: vm.strokeOpacity,
            onStrokeCompleted: { addStrokeWithUndo(StrokeConverter.convert($0)) },
            onStrokeErased: { handleErase($0) },
            isInteractive: vm.appMode == .draw,
            viewBridge: viewBridge
        )
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .pencilDoubleTap)) { _ in
            vm.handlePencilDoubleTap()
        }
    }

    @ViewBuilder
    private var drawModeControls: some View {
        if vm.showToolbar {
            FloatingToolbar(
                selectedTool: $vm.selectedTool,
                strokeWidth: $vm.strokeWidth,
                strokeOpacity: $vm.strokeOpacity,
                onUndo: { undoManager?.undo() },
                onRedo: { undoManager?.redo() },
                onClear: { clearWithUndo() }
            )
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) { vm.showToolbar.toggle() }
        } label: {
            Image(systemName: vm.showToolbar ? "chevron.down.circle.fill" : "ellipsis.circle")
                .font(.title2)
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.bottom, 16)
    }

    // MARK: - Document sync

    private func loadDrawingData() {
        if !drawingData.isEmpty, let loaded = try? PKDrawing(data: drawingData) {
            pkDrawing = loaded
        }
        reconcileLoadedStores()
    }

    /// Documents written while the ghost-stroke bug was live (see the
    /// programmatic-echo guard in CanvasView) can hold more model strokes
    /// than visible ink. All index-paired bookkeeping (erase, lift hide,
    /// commit parity) assumes canvas.strokes ↔ pkDrawing are 1:1, so a
    /// mismatched document self-heals on load: the visible drawing wins,
    /// the model is rebuilt from it, and sculpt objects whose source ink no
    /// longer resolves are pruned (the commit-time rule). Rebuilt strokes
    /// get fresh IDs, so healed documents lose exact-match re-entry once —
    /// re-selecting the ink simply re-infers.
    private func reconcileLoadedStores() {
        guard vm.canvas.strokes.count != pkDrawing.strokes.count else { return }
        vm.canvas.strokes = pkDrawing.strokes.map { StrokeConverter.convert($0) }
        let liveIDs = Set(vm.canvas.strokes.map(\.id))
        sculptObjects.removeAll { $0.sourceStrokeIDs.isDisjoint(with: liveIDs) }
        documentCanvas = vm.canvas
    }

    private func debounceSyncDrawing(_ newDrawing: PKDrawing) {
        drawingSyncTask?.cancel()
        drawingSyncTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            drawingData = newDrawing.dataRepresentation()
        }
    }

    private func flushToDocument() {
        // Mid-session pkDrawing intentionally lacks the selection's hidden ink;
        // that state must never reach disk (it would corrupt the drawing file).
        guard vm.appMode != .edit else { return }
        drawingSyncTask?.cancel()
        documentCanvas = vm.canvas
        drawingData = pkDrawing.dataRepresentation()
    }

    private func saveToDocument() {
        flushToDocument()
        withAnimation { vm.showSavedMessage = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { vm.showSavedMessage = false }
        }
    }

    // MARK: - Undo-aware actions

    private func addStrokeWithUndo(_ stroke: Stroke) {
        vm.addStroke(stroke)
        undoManager?.registerUndo(withTarget: UndoProxy.shared) { _ in
            // Mid-session, pkDrawing intentionally lacks the hidden (lifted)
            // ink, so positional closures registered in draw mode must not
            // fire: dropLast would remove the WRONG PK stroke and corrupt
            // canvas/pkDrawing parity for good. The undo action is consumed
            // as a no-op (acceptable — session-scoped closures like
            // handleEditCanvasStroke's remain valid because session strokes
            // stay parallel in both stores).
            guard vm.appMode != .edit else { return }
            vm.removeStroke(id: stroke.id)
            pkDrawing = PKDrawing(strokes: pkDrawing.strokes.dropLast())
        }
    }

    private func handleErase(_ removedIndices: [Int]) {
        for index in removedIndices.reversed() {
            guard index < vm.canvas.strokes.count else { continue }
            let stroke = vm.canvas.strokes[index]
            vm.removeStroke(id: stroke.id)
            undoManager?.registerUndo(withTarget: UndoProxy.shared) { _ in
                // Mid-session, pkDrawing intentionally lacks the hidden
                // (lifted) ink, so draw-mode closures must not fire: re-adding
                // canvas ink here (its PK side is restored separately) would
                // desync the stores. Consumed as a no-op.
                guard vm.appMode != .edit else { return }
                vm.addStroke(stroke)
            }
        }
    }

    private func clearWithUndo() {
        let previousStrokes = vm.canvas.strokes
        let previousDrawing = pkDrawing
        vm.clearStrokes()
        pkDrawing = PKDrawing()
        undoManager?.registerUndo(withTarget: UndoProxy.shared) { _ in
            vm.canvas.strokes = previousStrokes
            pkDrawing = previousDrawing
        }
    }

    // MARK: - 2.5D edit session

    private var editOverlay: some View {
        // vm.editSessionStrokes is populated by the VM BEFORE appMode flips
        // to .edit, so the overlay constructed by the body evaluation that
        // first sees .edit always receives the session's strokes — unlike a
        // parent @State copied in onChange, which runs after this evaluation
        // (that ordering handed the overlay [] and made every fresh lift
        // fail with the "Couldn't lift that selection" toast).
        Edit25DOverlay(
            sourceStrokes: vm.editSessionStrokes,
            sculptObjects: $sculptObjects,
            onCommit: handleEditCommit,
            onCanvasStroke: handleEditCanvasStroke,
            onInferenceFailed: cancelEditSession,
            onSessionInvalidated: dismantleEditSession,
            onSourceStrokesResolved: handleSourceStrokesResolved
        )
        .ignoresSafeArea()
        .transition(.opacity)
    }

    /// Index at which a restored (unlifted) PK stroke must be re-inserted so
    /// the visible pkDrawing stays parity-correct with what canvas.strokes
    /// becomes once the still-hidden (lifted) strokes leave the model at
    /// commit: its original index minus the still-hidden strokes before it.
    nonisolated static func parityInsertionIndex(originalIndex: Int,
                                                 stillHiddenOriginalIndices: [Int]) -> Int {
        originalIndex - stillHiddenOriginalIndices.filter { $0 < originalIndex }.count
    }

    /// The mesh is ready (fresh lift) or already present (re-entry): hide
    /// the PK ink riding the mesh, in the same main-actor turn that mounts
    /// the mesh view — until then the ink stays visible as the lift
    /// placeholder. `hidden` comes from the overlay (on re-entry it covers
    /// the object's whole lifted ink, which can be wider than the
    /// selection); `unlifted` strokes are never hidden and survive commit
    /// untouched. canvas.strokes keeps the originals until commit.
    private func handleSourceStrokesResolved(_ hidden: Set<UUID>, _ unlifted: Set<UUID>) {
        unliftedSourceIDs = unlifted
        // After the hide below, pkDrawing is no longer index-parallel with
        // canvas.strokes, so a spurious second report must not re-pair
        // indices. (The overlay reports exactly once per session.)
        guard hiddenPKStrokes.isEmpty else { return }
        let liftedIDs = hidden
        guard !liftedIDs.isEmpty else { return }
        var kept: [PKStroke] = []
        var removed: [(index: Int, id: UUID, stroke: PKStroke)] = []
        for (i, pk) in pkDrawing.strokes.enumerated() {
            if i < vm.canvas.strokes.count, liftedIDs.contains(vm.canvas.strokes[i].id) {
                removed.append((index: i, id: vm.canvas.strokes[i].id, stroke: pk))
            } else {
                kept.append(pk)
            }
        }
        hiddenPKStrokes = removed
        pkDrawing = PKDrawing(strokes: kept)
    }

    /// Snapshot pre-session state. The selection's PK ink intentionally
    /// stays VISIBLE while inference runs — it is the lift placeholder
    /// (spec: "ink lifts with a ghost placeholder until the mesh arrives");
    /// handleSourceStrokesLifted hides it when the mesh mounts. Runs before
    /// the overlay's onAppear (onChange fires within the same transaction
    /// that inserts the overlay), so the resets here can't clobber a
    /// re-entry's hide.
    private func beginEditSession() {
        // Undo of this session's commit must restore the pre-session world,
        // not a commit-time snapshot that already carries the session's
        // orientation/scale writes.
        preSessionObjects = sculptObjects
        hiddenPKStrokes = []
        unliftedSourceIDs = []
    }

    /// Teardown for an EXTERNALLY invalidated session: an undo restored
    /// canvas/pkDrawing/sculptObjects as a consistent pre-commit triple out
    /// from under the session, so its bookkeeping is stale. Unlike
    /// cancelEditSession — whose re-insertion is only valid while pkDrawing
    /// still holds the session's kept-drawing — nothing may be re-inserted
    /// here (hiddenPKStrokes would duplicate ink the undo already restored),
    /// and no toast: the undo's effect is already visible on the canvas.
    private func dismantleEditSession() {
        hiddenPKStrokes = []
        unliftedSourceIDs = []
        preSessionObjects = []
        withAnimation(.easeInOut(duration: 0.2)) { vm.exitEditMode() }
    }

    /// Inference failed: restore any hidden ink exactly as it was. (With the
    /// deferred hide, failure normally happens before anything was hidden —
    /// the loop is then a no-op and the visible ink was never touched.)
    private func cancelEditSession() {
        var strokes = pkDrawing.strokes
        for entry in hiddenPKStrokes.sorted(by: { $0.index < $1.index }) {
            strokes.insert(entry.stroke, at: min(entry.index, strokes.count))
        }
        pkDrawing = PKDrawing(strokes: strokes)
        hiddenPKStrokes = []
        unliftedSourceIDs = []
        preSessionObjects = []
        withAnimation(.easeInOut(duration: 0.2)) { vm.exitEditMode() }
        withAnimation { showInferenceFailedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showInferenceFailedToast = false }
        }
    }

    /// A flat stroke drawn beside the shape mid-session: ordinary canvas ink.
    private func handleEditCanvasStroke(_ stroke: Stroke) {
        vm.addStroke(stroke)
        pkDrawing = PKDrawing(strokes: pkDrawing.strokes + [StrokeConverter.toPKStroke(stroke)])
        undoManager?.registerUndo(withTarget: UndoProxy.shared) { _ in
            // Session-scoped, but a blind dropLast would still be wrong once:
            // undoing an EARLIER commit restores canvas/pkDrawing wholesale
            // and can wipe this stroke while this registration is still
            // stacked — a later fire would then dropLast an innocent stroke.
            // So: no-op if the stroke is gone, and remove the PK stroke at
            // the parity index of the stroke's canvas position (mid-session,
            // still-hidden lifted ink offsets it; post-session it's 1:1).
            guard let canvasIdx = vm.canvas.strokes.firstIndex(where: { $0.id == stroke.id }) else { return }
            let pkIdx = Self.parityInsertionIndex(originalIndex: canvasIdx,
                                                  stillHiddenOriginalIndices: hiddenPKStrokes.map(\.index))
            vm.removeStroke(id: stroke.id)
            var strokes = pkDrawing.strokes
            if pkIdx < strokes.count { strokes.remove(at: pkIdx) }
            pkDrawing = PKDrawing(strokes: strokes)
        }
    }

    /// Bake: lifted originals out, rotated projection in; unlifted originals
    /// stay untouched. One undoable operation.
    private func handleEditCommit(_ objectID: UUID, _ bakedStrokes: [Stroke]) {
        let previousCanvasStrokes = vm.canvas.strokes
        let previousPKDrawing = PKDrawing(strokes: hiddenPKStrokes
            .sorted(by: { $0.index < $1.index })
            .reduce(into: pkDrawing.strokes) { $0.insert($1.stroke, at: min($1.index, $0.count)) })
        // Pre-session snapshot: undoing a commit must also undo the session's
        // orientation/scale writes, which land before this handler runs.
        let previousObjects = preSessionObjects

        // Only strokes that actually enter the canvas (the loop below drops
        // degenerate single-point bakes) may form the object's new source
        // identity — dangling IDs would defeat exact-match re-entry.
        let insertedBaked = bakedStrokes.filter { $0.points.count > 1 }

        // Remove lifted source strokes from the model (their PK ink is already
        // hidden). Unlifted ones were never hidden from pkDrawing's visible
        // set (handleSourceStrokesLifted skips them) and stay in canvas.
        if let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) {
            for id in sculptObjects[idx].sourceStrokeIDs where !unliftedSourceIDs.contains(id) {
                vm.removeStroke(id: id)
            }
            if insertedBaked.isEmpty {
                // The user erased all surface ink: nothing bakes back, so the
                // object would retain only unmatchable IDs. Spec error
                // handling: "originals are simply removed; object is
                // discarded". Unlifted originals still carry through
                // untouched as ordinary flat ink.
                sculptObjects.remove(at: idx)
            } else {
                // Re-selection of "the shape" must match baked ink + carried-through
                // originals, so both sets form the object's new source identity.
                sculptObjects[idx].sourceStrokeIDs = Set(insertedBaked.map(\.id))
                    .union(unliftedSourceIDs)
                sculptObjects[idx].unliftedStrokeIDs = unliftedSourceIDs
            }
        }

        // Insert the baked ink into both stores (kept parallel: both appended at the end).
        var newPKStrokes: [PKStroke] = []
        for stroke in insertedBaked {
            vm.addStroke(stroke)
            newPKStrokes.append(StrokeConverter.toPKStroke(stroke))
        }
        pkDrawing = PKDrawing(strokes: pkDrawing.strokes + newPKStrokes)

        // Prune fully-orphaned objects: an object whose source ink no longer
        // exists on the canvas can never be re-entered (entry is an exact
        // sourceStrokeIDs match), so without pruning they accumulate in the
        // document forever. The committed object's new sourceStrokeIDs are
        // live by construction, so it survives. Covered by the same undo
        // registration below (preSessionObjects restore).
        let liveIDs = Set(vm.canvas.strokes.map(\.id))
        sculptObjects.removeAll { $0.sourceStrokeIDs.isDisjoint(with: liveIDs) }

        hiddenPKStrokes = []
        unliftedSourceIDs = []
        preSessionObjects = []
        withAnimation(.easeInOut(duration: 0.2)) { vm.exitEditMode() }

        undoManager?.registerUndo(withTarget: UndoProxy.shared) { _ in
            // An open session's bookkeeping (hidden ink, pre-session
            // snapshot) is invalid the moment this restore rewrites the
            // world. The overlay's own invalidation only fires when the
            // session's OBJECT vanishes — undoing an older commit of the
            // SAME object keeps it alive, leaving the session floating over
            // the restored 2D ink (double image) and duplicating strokes at
            // its next commit. Dismantle any live session first, then
            // restore onto a sessionless canvas.
            if vm.appMode == .edit { dismantleEditSession() }
            vm.canvas.strokes = previousCanvasStrokes
            pkDrawing = previousPKDrawing
            sculptObjects = previousObjects
        }
    }
}

private final class UndoProxy {
    static let shared = UndoProxy()
}
