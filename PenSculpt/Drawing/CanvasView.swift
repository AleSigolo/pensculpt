import SwiftUI
import PencilKit

struct CanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var selectedTool: DrawingTool
    var strokeWidth: CGFloat
    var strokeOpacity: CGFloat
    var onStrokeCompleted: ((PKStroke) -> Void)?
    var onStrokeErased: ((_ removedIndices: [Int]) -> Void)?
    var isInteractive: Bool = true
    var viewBridge: ViewBridge?

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.drawing = drawing
        context.coordinator.resetTracking(to: canvasView.drawing)
        canvasView.tool = pkTool(for: selectedTool)
        canvasView.drawingPolicy = .pencilOnly
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
        canvasView.delegate = context.coordinator
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.contentInsetAdjustmentBehavior = .never
        viewBridge?.canvasView = canvasView

        // Apple Pencil double-tap interaction
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)

        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        canvasView.isUserInteractionEnabled = isInteractive
        canvasView.tool = pkTool(for: selectedTool)
        if canvasView.drawing != drawing {
            context.coordinator.setDrawingProgrammatically(drawing, on: canvasView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func pkTool(for tool: DrawingTool) -> any PKTool {
        switch tool {
        case .pen:
            let color = UIColor.black.withAlphaComponent(strokeOpacity)
            return PKInkingTool(.pen, color: color, width: strokeWidth)
        case .eraser:
            return PKEraserTool(.vector)
        case .pixelEraser:
            return PKEraserTool(.bitmap, width: strokeWidth)
        }
    }

    static func removedStrokeIndices(previous: [PKStroke], current: [PKStroke]) -> [Int] {
        var removedIndices: [Int] = []
        var ci = 0
        for pi in 0..<previous.count {
            if ci < current.count && previous[pi].renderBounds == current[ci].renderBounds {
                ci += 1
            } else {
                removedIndices.append(pi)
            }
        }
        return removedIndices
    }

    class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let parent: CanvasView
        private var previousStrokeCount = 0
        private var previousDrawing = PKDrawing()
        private var isProgrammaticUpdate = false

        init(_ parent: CanvasView) {
            self.parent = parent
        }

        func resetTracking(to drawing: PKDrawing) {
            previousDrawing = drawing
            previousStrokeCount = drawing.strokes.count
        }

        /// Assigns a drawing that came FROM the bound model (document load,
        /// updateUIView sync). PKCanvasView re-reports the assignment through
        /// canvasViewDrawingDidChange — sometimes synchronously inside the
        /// setter — and that echo must never be treated as user input (the
        /// count-jump branch would append a duplicate stroke to the model,
        /// desyncing canvas.strokes from pkDrawing by index; every later
        /// erase then removes the wrong model stroke and accumulates ghost
        /// ink that selection/lift still see). Equality checks can't detect
        /// the echo — PencilKit re-encodes assigned drawings — so the window
        /// is flagged explicitly and tracking is reset to the canvas's own
        /// post-assignment representation.
        func setDrawingProgrammatically(_ drawing: PKDrawing, on canvasView: PKCanvasView) {
            isProgrammaticUpdate = true
            canvasView.drawing = drawing
            isProgrammaticUpdate = false
            resetTracking(to: canvasView.drawing)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let currentDrawing = canvasView.drawing
            let currentCount = currentDrawing.strokes.count

            // Synchronous echo of a programmatic assignment (see
            // setDrawingProgrammatically). Async echoes arrive after the
            // flag clears, but by then tracking was reset — counts match and
            // neither branch below fires.
            if isProgrammaticUpdate { return }

            if currentCount > previousStrokeCount,
               let lastStroke = currentDrawing.strokes.last {
                parent.onStrokeCompleted?(lastStroke)
            } else if currentCount < previousStrokeCount {
                let removedIndices = CanvasView.removedStrokeIndices(
                    previous: previousDrawing.strokes,
                    current: currentDrawing.strokes
                )
                parent.onStrokeErased?(removedIndices)
            }

            parent.drawing = currentDrawing
            previousDrawing = currentDrawing
            previousStrokeCount = currentCount
        }

        // MARK: - UIPencilInteractionDelegate

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            NotificationCenter.default.post(name: .pencilDoubleTap, object: nil)
        }
    }
}

extension Notification.Name {
    static let pencilDoubleTap = Notification.Name("PenSculptPencilDoubleTap")
}
