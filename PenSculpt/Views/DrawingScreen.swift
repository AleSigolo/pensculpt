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
    @State private var projectedStrokeIDs: Set<UUID> = []
    @State private var autoProjectStrokes = true
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
            if vm.appMode == .select && vm.hasSelection { sculptButton }
        }
        .overlay(alignment: .top) { savedMessageOverlay }
        .fullScreenCover(isPresented: $vm.showSculptScreen, onDismiss: projectSurfaceStrokes) {
            SculptScreen(strokes: vm.selectedStrokes, sculptObjects: $sculptObjects,
                         autoProjectStrokes: $autoProjectStrokes)
        }
        .toolbar { navBarItems }
        .onAppear { loadDrawingData() }
        .onChange(of: vm.canvas) { _, _ in
            guard vm.autosaveEnabled else { return }
            documentCanvas = vm.canvas
        }
        .onChange(of: pkDrawing) { _, newDrawing in
            guard vm.autosaveEnabled else { return }
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
        if vm.hasSelection {
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

    private var sculptButton: some View {
        Button { vm.showSculptScreen = true } label: {
            Label("Sculpt", systemImage: "cube")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.blue, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.bottom, 30)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
    }

    private var navBarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { vm.toggleMode() }
                } label: {
                    Image(systemName: vm.appMode == .draw ? "lasso" : "pencil.tip")
                        .font(.title3)
                        .foregroundStyle(.blue)
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

                Button { saveToDocument() } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.body)
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

    private func projectSurfaceStrokes() {
        guard autoProjectStrokes else { return }
        var newPKStrokes: [PKStroke] = []
        for obj in sculptObjects {
            for surfaceStroke in obj.surfaceStrokes
                where surfaceStroke.points.count > 1 && !projectedStrokeIDs.contains(surfaceStroke.id) {
                let stroke2D = surfaceStroke.projectTo2D()
                vm.addStroke(stroke2D)
                newPKStrokes.append(StrokeConverter.toPKStroke(stroke2D))
                projectedStrokeIDs.insert(surfaceStroke.id)
            }
        }
        if !newPKStrokes.isEmpty {
            pkDrawing = PKDrawing(strokes: pkDrawing.strokes + newPKStrokes)
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
}

private final class UndoProxy {
    static let shared = UndoProxy()
}
