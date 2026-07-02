import Foundation
import Observation

@Observable
class DrawingViewModel {
    var canvas: Canvas
    var strokeWidth: CGFloat = 3
    var strokeOpacity: CGFloat = 1
    var showToolbar = false
    var showSavedMessage = false
    var autosaveEnabled = true
    var appMode: AppMode = .draw
    var lassoPoints: [CGPoint] = []
    var selectedStrokeIDs: Set<UUID> = []
    var activeStrategy: SelectionStrategyKind = .lasso

    /// Tracks the last eraser type for pencil double-tap toggle.
    private(set) var lastEraserType: DrawingTool = .eraser

    /// Setting the tool automatically tracks the last eraser type.
    var selectedTool: DrawingTool = .pen {
        didSet {
            if selectedTool.isEraser {
                lastEraserType = selectedTool
            }
        }
    }

    init(canvas: Canvas) {
        self.canvas = canvas
    }

    var selectedStrokes: [Stroke] {
        canvas.strokes.filter { selectedStrokeIDs.contains($0.id) }
    }

    var hasSelection: Bool {
        !selectedStrokeIDs.isEmpty
    }

    // MARK: - Mode switching

    func toggleMode() {
        guard appMode != .edit else { return }
        if appMode == .draw {
            appMode = .select
        } else {
            appMode = .draw
            lassoPoints = []
            selectedStrokeIDs = []
            activeStrategy = .lasso
        }
    }

    // MARK: - Tool management

    func handlePencilDoubleTap() {
        guard appMode == .draw else { return }
        if selectedTool == .pen {
            selectedTool = lastEraserType
        } else {
            selectedTool = .pen
        }
    }

    // MARK: - Selection

    func handleLassoCompleted(polygon: [CGPoint]) {
        selectedStrokeIDs = LassoSelection.selectedStrokeIDs(
            strokes: canvas.strokes,
            polygon: polygon
        )
        if hasSelection { appMode = .edit }
    }

    func activateSmartStrategy() {
        activeStrategy = .smart
    }

    func handleSmartSelectCommitted(strokeIDs: Set<UUID>) {
        selectedStrokeIDs = strokeIDs
        if hasSelection { appMode = .edit }
    }

    /// Leaves 2.5D edit mode and returns to drawing with a clean selection state.
    func exitEditMode() {
        appMode = .draw
        lassoPoints = []
        selectedStrokeIDs = []
        activeStrategy = .lasso
    }

    // MARK: - Stroke mutations

    func addStroke(_ stroke: Stroke) {
        canvas.addStroke(stroke)
    }

    func removeStroke(id: UUID) {
        canvas.removeStroke(id: id)
    }

    func clearStrokes() {
        canvas.clearStrokes()
    }
}
