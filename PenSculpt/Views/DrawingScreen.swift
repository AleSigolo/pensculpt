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
    @State private var editSourceStrokes: [Stroke] = []
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
        if vm.showSavedMessage {
            Text("Saved!")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.top, 60)
        }
        if showInferenceFailedToast {
            Text("Couldn't lift that selection")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.top, 60)
        }
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
        Edit25DOverlay(
            sourceStrokes: editSourceStrokes,
            sculptObjects: $sculptObjects,
            onCommit: handleEditCommit,
            onCanvasStroke: handleEditCanvasStroke,
            onInferenceFailed: cancelEditSession,
            onSourceStrokesLifted: handleSourceStrokesLifted
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

    /// Some selected strokes couldn't be lifted onto the mesh (e.g. ink the
    /// lasso caught that lies off the inferred shape). Un-hide their PK ink —
    /// they stay ordinary flat strokes and survive commit untouched.
    private func handleSourceStrokesLifted(_ unlifted: Set<UUID>) {
        unliftedSourceIDs = unlifted
        guard !unlifted.isEmpty else { return }
        let toRestore = hiddenPKStrokes.filter { unlifted.contains($0.id) }
        hiddenPKStrokes.removeAll { unlifted.contains($0.id) }
        let stillHidden = hiddenPKStrokes.map(\.index)
        var strokes = pkDrawing.strokes
        for entry in toRestore.sorted(by: { $0.index < $1.index }) {
            let idx = Self.parityInsertionIndex(originalIndex: entry.index,
                                                stillHiddenOriginalIndices: stillHidden)
            strokes.insert(entry.stroke, at: min(idx, strokes.count))
        }
        pkDrawing = PKDrawing(strokes: strokes)
    }

    /// Snapshot the selection and hide its PK ink so the lifted mesh replaces
    /// it visually. canvas.strokes keeps the originals until commit.
    private func beginEditSession() {
        editSourceStrokes = vm.selectedStrokes
        // Undo of this session's commit must restore the pre-session world,
        // not a commit-time snapshot that already carries the session's
        // orientation/scale writes.
        preSessionObjects = sculptObjects
        let ids = vm.selectedStrokeIDs
        var kept: [PKStroke] = []
        var removed: [(index: Int, id: UUID, stroke: PKStroke)] = []
        for (i, pk) in pkDrawing.strokes.enumerated() {
            if i < vm.canvas.strokes.count, ids.contains(vm.canvas.strokes[i].id) {
                removed.append((index: i, id: vm.canvas.strokes[i].id, stroke: pk))
            } else {
                kept.append(pk)
            }
        }
        hiddenPKStrokes = removed
        unliftedSourceIDs = []
        pkDrawing = PKDrawing(strokes: kept)
    }

    /// Inference failed: restore the hidden ink exactly as it was.
    private func cancelEditSession() {
        var strokes = pkDrawing.strokes
        for entry in hiddenPKStrokes.sorted(by: { $0.index < $1.index }) {
            strokes.insert(entry.stroke, at: min(entry.index, strokes.count))
        }
        pkDrawing = PKDrawing(strokes: strokes)
        hiddenPKStrokes = []
        editSourceStrokes = []
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
            vm.removeStroke(id: stroke.id)
            pkDrawing = PKDrawing(strokes: pkDrawing.strokes.dropLast())
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
        // hidden). Unlifted ones were never removed from pkDrawing's visible
        // set (handleSourceStrokesLifted restored them) and stay in canvas.
        if let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) {
            for id in sculptObjects[idx].sourceStrokeIDs where !unliftedSourceIDs.contains(id) {
                vm.removeStroke(id: id)
            }
            // Re-selection of "the shape" must match baked ink + carried-through
            // originals, so both sets form the object's new source identity.
            sculptObjects[idx].sourceStrokeIDs = Set(insertedBaked.map(\.id))
                .union(unliftedSourceIDs)
            sculptObjects[idx].unliftedStrokeIDs = unliftedSourceIDs
        }

        // Insert the baked ink into both stores (kept parallel: both appended at the end).
        var newPKStrokes: [PKStroke] = []
        for stroke in insertedBaked {
            vm.addStroke(stroke)
            newPKStrokes.append(StrokeConverter.toPKStroke(stroke))
        }
        pkDrawing = PKDrawing(strokes: pkDrawing.strokes + newPKStrokes)

        hiddenPKStrokes = []
        editSourceStrokes = []
        unliftedSourceIDs = []
        preSessionObjects = []
        withAnimation(.easeInOut(duration: 0.2)) { vm.exitEditMode() }

        undoManager?.registerUndo(withTarget: UndoProxy.shared) { _ in
            vm.canvas.strokes = previousCanvasStrokes
            pkDrawing = previousPKDrawing
            sculptObjects = previousObjects
        }
    }
}

private final class UndoProxy {
    static let shared = UndoProxy()
}
