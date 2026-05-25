import SwiftUI
import UIKit

struct SelectionOverlay: UIViewRepresentable {
    @Binding var lassoPoints: [CGPoint]
    var allStrokes: [Stroke]
    var viewBridge: ViewBridge?
    var onLassoCompleted: ([CGPoint]) -> Void
    var onGrowGestureStarted: (GrowOrigin) -> Void
    var onGrowGestureEnded: () -> Void
    var onGrowGestureCancelled: () -> Void

    static let longPressMinimumDuration: CFTimeInterval = 0.15
    // Pencil contact wobbles more when tilted; 5pt cancels the LP for natural
    // hand jitter, so allow up to 15pt before treating the gesture as a pan.
    static let longPressAllowableMovement: CGFloat = 15.0
    static let strokeHitTolerance: CGFloat = 8.0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SelectionView {
        let view = SelectionView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        view.onLassoCompleted = { context.coordinator.parent.onLassoCompleted($0) }
        view.onGrowGestureStarted = { context.coordinator.parent.onGrowGestureStarted($0) }
        view.onGrowGestureEnded = { context.coordinator.parent.onGrowGestureEnded() }
        view.onGrowGestureCancelled = { context.coordinator.parent.onGrowGestureCancelled() }
        view.installRecognizers()
        return view
    }

    func updateUIView(_ uiView: SelectionView, context: Context) {
        context.coordinator.parent = self
        uiView.targetView = viewBridge?.canvasView
        uiView.allStrokes = allStrokes
        if lassoPoints.isEmpty && !uiView.displayPoints.isEmpty {
            uiView.clearLasso()
        }
    }

    final class Coordinator {
        var parent: SelectionOverlay
        init(_ parent: SelectionOverlay) { self.parent = parent }
    }
}

final class SelectionView: UIView {
    var coordinator: SelectionOverlay.Coordinator?

    var displayPoints: [CGPoint] = []
    private(set) var hitTestPoints: [CGPoint] = []
    weak var targetView: UIView?
    private(set) var isClosed = false
    var allStrokes: [Stroke] = []

    var onLassoCompleted: (([CGPoint]) -> Void)?
    var onGrowGestureStarted: ((GrowOrigin) -> Void)?
    var onGrowGestureEnded: (() -> Void)?
    var onGrowGestureCancelled: (() -> Void)?

    private var panRecognizer: UIPanGestureRecognizer?
    private var longPressRecognizer: UILongPressGestureRecognizer?

    // MARK: - Recognizer setup

    func installRecognizers() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        panRecognizer = pan

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = SelectionOverlay.longPressMinimumDuration
        lp.allowableMovement = SelectionOverlay.longPressAllowableMovement
        addGestureRecognizer(lp)
        longPressRecognizer = lp
    }

    // MARK: - Lasso path (testable)

    func clearLasso() {
        displayPoints = []
        hitTestPoints = []
        isClosed = false
        coordinator?.parent.lassoPoints = []
        setNeedsDisplay()
    }

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
            onLassoCompleted?(hitTestPoints)
        } else {
            displayPoints = []
            hitTestPoints = []
            coordinator?.parent.lassoPoints = []
        }
        setNeedsDisplay()
    }

    // MARK: - Grow path (testable)

    func beginGrow(at canvasPoint: CGPoint, strokes: [Stroke]) {
        let origin: GrowOrigin
        if let hit = Self.hitStroke(at: canvasPoint, in: strokes,
                                    tolerance: SelectionOverlay.strokeHitTolerance) {
            origin = .stroke(strokeID: hit.id, anchor: canvasPoint)
        } else {
            origin = .point(canvasPoint)
        }
        onGrowGestureStarted?(origin)
    }

    func endGrow() {
        onGrowGestureEnded?()
    }

    func cancelGrow() {
        onGrowGestureCancelled?()
    }

    static func hitStroke(at point: CGPoint, in strokes: [Stroke], tolerance: CGFloat) -> Stroke? {
        var best: (Stroke, CGFloat)?
        for s in strokes {
            for sp in s.points {
                let d = hypot(sp.location.x - point.x, sp.location.y - point.y)
                if d <= tolerance {
                    if let cur = best, cur.1 <= d { continue }
                    best = (s, d)
                }
            }
        }
        return best?.0
    }

    // MARK: - Recognizer handlers

    private func points(for location: CGPoint, in view: UIView) -> (display: CGPoint, target: CGPoint) {
        let display = location
        let target = targetView.map { view.convert(location, to: $0) } ?? display
        return (display, target)
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let location = gr.location(in: self)
        let p = points(for: location, in: self)
        switch gr.state {
        case .began:
            beginStroke(displayPoint: p.display, targetPoint: p.target)
        case .changed:
            continueStroke(displayPoint: p.display, targetPoint: p.target)
        case .ended, .cancelled:
            endStroke()
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        switch gr.state {
        case .began:
            let display = gr.location(in: self)
            let target = targetView.map { gr.view!.convert(display, to: $0) } ?? display
            beginGrow(at: target, strokes: allStrokes)
        case .ended:
            endGrow()
        case .cancelled, .failed:
            // System-level interruption (backgrounding, multitouch, mode change)
            // discards the partial selection rather than committing it.
            cancelGrow()
        default:
            break
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard displayPoints.count > 1, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [8, 4])
        ctx.beginPath()
        ctx.move(to: displayPoints[0])
        for p in displayPoints.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }
}
