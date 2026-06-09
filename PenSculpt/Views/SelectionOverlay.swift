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

    // MARK: - Smart-grow state

    /// Snapshot of canvas strokes (canvas coordinates) for clustering + drawing.
    var strokes: [Stroke] = []
    /// Reach-ring center in this view's (display) coordinates; nil when inactive.
    private(set) var smartHoldDisplayPoint: CGPoint?
    /// Current reach radius (canvas-space distance) for drawing the ring.
    private(set) var smartReach: CGFloat = 0
    /// Stroke IDs currently inside the reach.
    private(set) var smartSelectedIDs: Set<UUID> = []

    private var smartDistances: [(group: StrokeGroup, distance: CGFloat)] = []

    func clearLasso() {
        displayPoints = []
        hitTestPoints = []
        isClosed = false
        setNeedsDisplay()
    }

    // MARK: - Point handling (testable)

    func beginStroke(displayPoint: CGPoint, targetPoint: CGPoint) {
        clearSmartGrow()
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

    // MARK: - Smart-grow methods

    /// Whether a touch that has moved `movement` points still counts as a hold.
    /// Inclusive: `movement == slop` is treated as a hold.
    static func isWithinSlop(movement: CGFloat, slop: CGFloat) -> Bool {
        movement <= slop
    }

    /// Begin smart-grow: cluster the snapshot, seed at the nearest object.
    /// `targetPoint` is in canvas coordinates; `displayPoint` in view coordinates.
    func beginSmartGrow(displayPoint: CGPoint, targetPoint: CGPoint) {
        clearLasso()
        smartHoldDisplayPoint = displayPoint
        let groups = StrokeClustering.groups(from: strokes,
                                             linkDistance: SelectionConfig.clusterLinkDistance)
        smartDistances = SmartSelection.groupDistances(groups: groups, strokes: strokes,
                                                       from: targetPoint)
        smartReach = SmartSelection.nearestDistance(smartDistances)
        smartSelectedIDs = SmartSelection.groupsWithin(reach: smartReach, distances: smartDistances)
        setNeedsDisplay()
    }

    /// Grow the reach. Returns true when new strokes were pulled in (for haptics).
    /// Monotonic: the selection only ever accumulates — a smaller `reach` never
    /// removes already-selected strokes.
    @discardableResult
    func advanceSmartGrow(reach: CGFloat) -> Bool {
        smartReach = reach
        let updated = SmartSelection.groupsWithin(reach: reach, distances: smartDistances)
        let grew = !updated.subtracting(smartSelectedIDs).isEmpty
        smartSelectedIDs.formUnion(updated)
        setNeedsDisplay()
        return grew
    }

    /// Finish smart-grow, returning the committed stroke IDs and clearing state.
    func endSmartGrow() -> Set<UUID> {
        let committed = smartSelectedIDs
        clearSmartGrow()
        setNeedsDisplay()
        return committed
    }

    /// Resets smart-grow state (without committing). Called when a lasso gesture
    /// starts so the two gestures cannot leave stale state in each other.
    private func clearSmartGrow() {
        smartHoldDisplayPoint = nil
        smartReach = 0
        smartDistances = []
        smartSelectedIDs = []
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
