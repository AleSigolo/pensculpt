import SwiftUI
import UIKit

struct SelectionOverlay: UIViewRepresentable {
    @Binding var lassoPoints: [CGPoint]
    var onLassoCompleted: ([CGPoint]) -> Void
    var strokes: [Stroke] = []
    var activeStrategy: SelectionStrategyKind = .lasso
    var onSmartActivated: () -> Void = {}
    var onSmartSelectCompleted: (Set<UUID>) -> Void = { _ in }
    var viewBridge: ViewBridge?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SelectionView {
        let view = SelectionView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SelectionView, context: Context) {
        context.coordinator.parent = self
        uiView.targetView = viewBridge?.canvasView
        uiView.strokes = strokes
        uiView.activeStrategy = activeStrategy
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

    // MARK: - Gesture + display-link state

    var activeStrategy: SelectionStrategyKind = .lasso

    private var holdTimer: Timer?
    private var displayLink: CADisplayLink?
    private var touchStartDisplay: CGPoint = .zero
    private var touchStartTarget: CGPoint = .zero
    private var growthStartTime: CFTimeInterval = 0
    private var seedReach: CGFloat = 0
    private var isSmartGrowing = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)

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
        guard let touch = touches.first else { return }
        let p = points(for: touch)
        touchStartDisplay = p.display
        touchStartTarget = p.target

        if activeStrategy == .smart {
            startSmartGrow(display: p.display, target: p.target)
        } else {
            // Tentative lasso; a stationary hold will switch to smart.
            beginStroke(displayPoint: p.display, targetPoint: p.target)
            holdTimer = Timer.scheduledTimer(withTimeInterval: SelectionConfig.holdDelay,
                                             repeats: false) { [weak self] _ in
                self?.handleHoldFired()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let p = points(for: touch)

        if isSmartGrowing { return } // smart ignores drift; ring stays put

        let dx = p.display.x - touchStartDisplay.x
        let dy = p.display.y - touchStartDisplay.y
        let movement = (dx * dx + dy * dy).squareRoot()
        if !Self.isWithinSlop(movement: movement, slop: SelectionConfig.moveSlop) {
            holdTimer?.invalidate(); holdTimer = nil   // committed to lasso
        }
        continueStroke(displayPoint: p.display, targetPoint: p.target)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate(); holdTimer = nil
        if isSmartGrowing {
            finishSmartGrow()
        } else {
            endStroke()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdTimer?.invalidate(); holdTimer = nil
        if isSmartGrowing {
            stopDisplayLink()
            _ = endSmartGrow()
            isSmartGrowing = false
        } else {
            clearLasso()
        }
    }

    // MARK: - Smart-grow lifecycle helpers

    private func handleHoldFired() {
        guard !isSmartGrowing else { return }
        coordinator?.parent.onSmartActivated()           // flips toggle to .smart
        activeStrategy = .smart
        startSmartGrow(display: touchStartDisplay, target: touchStartTarget)
    }

    private func startSmartGrow(display: CGPoint, target: CGPoint) {
        isSmartGrowing = true
        haptics.prepare()
        beginSmartGrow(displayPoint: display, targetPoint: target)
        seedReach = smartReach
        growthStartTime = CACurrentMediaTime()
        if !smartSelectedIDs.isEmpty { haptics.impactOccurred() }  // seed tick
        startDisplayLink()
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(stepGrowth))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func stepGrowth() {
        let elapsed = CGFloat(CACurrentMediaTime() - growthStartTime)
        let reach = seedReach + SelectionConfig.growthRate * elapsed
        if advanceSmartGrow(reach: reach) {
            haptics.impactOccurred()                      // tick per new object
        }
    }

    private func finishSmartGrow() {
        stopDisplayLink()
        let committed = endSmartGrow()
        isSmartGrowing = false
        coordinator?.parent.onSmartSelectCompleted(committed)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Smart-grow visuals
        if let center = smartHoldDisplayPoint {
            // In-progress object highlights (blue), converted canvas → display.
            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes where smartSelectedIDs.contains(stroke.id) && stroke.points.count > 1 {
                ctx.beginPath()
                ctx.move(to: convertFromTarget(stroke.points[0].location))
                for point in stroke.points.dropFirst() {
                    ctx.addLine(to: convertFromTarget(point.location))
                }
                ctx.strokePath()
            }
            // Reach ring (reach is a canvas-space radius; canvas↔display are
            // same-scale sibling views, so it maps 1:1).
            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [])
            let r = max(smartReach, 1)
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }

        // Lasso path (unchanged)
        guard displayPoints.count > 1 else { return }
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

    /// Converts a point from target (canvas) coordinates into this view's coordinates.
    private func convertFromTarget(_ point: CGPoint) -> CGPoint {
        guard let target = targetView else { return point }
        return target.convert(point, to: self)
    }
}
