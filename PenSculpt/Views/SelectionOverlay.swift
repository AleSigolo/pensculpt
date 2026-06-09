import SwiftUI
import UIKit

struct SelectionOverlay: UIViewRepresentable {
    @Binding var lassoPoints: [CGPoint]
    var onLassoCompleted: ([CGPoint]) -> Void
    var viewBridge: ViewBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SelectionView {
        let view = SelectionView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SelectionView, context: Context) {
        context.coordinator.parent = self
        // Keep the target reference up to date
        uiView.targetView = viewBridge?.canvasView
        if lassoPoints.isEmpty && !uiView.displayPoints.isEmpty {
            uiView.clearLasso()
        }
    }

    class Coordinator {
        var parent: SelectionOverlay
        init(_ parent: SelectionOverlay) { self.parent = parent }
    }
}

class SelectionView: UIView {
    var coordinator: SelectionOverlay.Coordinator?
    /// Points in this view's coordinates — used for rendering the lasso path.
    var displayPoints: [CGPoint] = []
    /// Points in the target view's coordinates — used for hit-testing.
    private(set) var hitTestPoints: [CGPoint] = []
    /// The PKCanvasView to convert touch coordinates into.
    weak var targetView: UIView?
    private(set) var isClosed = false

    func clearLasso() {
        displayPoints = []
        hitTestPoints = []
        isClosed = false
        setNeedsDisplay()
    }

    // MARK: - Point handling (testable)

    func beginStroke(displayPoint: CGPoint, targetPoint: CGPoint) {
        if isClosed { clearLasso() }
        displayPoints = [displayPoint]
        hitTestPoints = [targetPoint]
        coordinator?.parent.lassoPoints = displayPoints
        setNeedsDisplay()
    }

    func continueStroke(displayPoint: CGPoint, targetPoint: CGPoint) {
        displayPoints.append(displayPoint)
        hitTestPoints.append(targetPoint)
        coordinator?.parent.lassoPoints = displayPoints
        setNeedsDisplay()
    }

    func endStroke() {
        if displayPoints.count > 2 {
            displayPoints.append(displayPoints[0])
            hitTestPoints.append(hitTestPoints[0])
            isClosed = true
            coordinator?.parent.lassoPoints = displayPoints
            coordinator?.parent.onLassoCompleted(hitTestPoints)
        } else {
            displayPoints = []
            hitTestPoints = []
            coordinator?.parent.lassoPoints = displayPoints
        }
        setNeedsDisplay()
    }

    // MARK: - UITouch handling

    private func points(for touch: UITouch) -> (display: CGPoint, target: CGPoint) {
        let display = touch.location(in: self)
        let target = targetView.map { touch.location(in: $0) } ?? display
        return (display, target)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first.map({ points(for: $0) }) else { return }
        beginStroke(displayPoint: p.display, targetPoint: p.target)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first.map({ points(for: $0) }) else { return }
        continueStroke(displayPoint: p.display, targetPoint: p.target)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endStroke()
    }

    override func draw(_ rect: CGRect) {
        guard displayPoints.count > 1, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 4])
        ctx.beginPath()
        ctx.move(to: displayPoints[0])
        for point in displayPoints.dropFirst() {
            ctx.addLine(to: point)
        }
        ctx.strokePath()
    }
}
