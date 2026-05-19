import Foundation
import Observation
import QuartzCore

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
    var showSculptScreen = false

    // Grow-selection lifecycle state. `growSession` is non-nil while the user
    // is holding; `growthFrame` is the latest tick snapshot driving the
    // visualization overlay. Both are reset on gesture end.
    var growSession: GrowSession?
    var growthFrame: GrowFrame?
    private var displayLink: CADisplayLink?
    private var lastTickTimestamp: CFTimeInterval = 0
    /// Snapshot of `selectedStrokeIDs` at the moment a grow gesture started, so
    /// a cancellation (system interruption, mode toggle) can revert exactly.
    private var selectionBeforeGrow: Set<UUID>?

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
        if appMode == .draw {
            appMode = .select
        } else {
            // Toggling out of select while a grow gesture is active discards it.
            if growSession != nil { handleGrowGestureCancelled() }
            appMode = .draw
            lassoPoints = []
            selectedStrokeIDs = []
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
        selectedStrokeIDs = LassoStrategy.selectedStrokeIDs(
            strokes: canvas.strokes,
            polygon: polygon
        )
        // DIAG: log every stroke and whether it was selected.
        let polyBounds = polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        print("[LASSO-DIAG] polygon bounds=\(polyBounds) points=\(polygon.count) totalStrokes=\(canvas.strokes.count) selected=\(selectedStrokeIDs.count)")
        for s in canvas.strokes {
            let inside = selectedStrokeIDs.contains(s.id) ? "IN " : "OUT"
            print("[LASSO-DIAG] \(inside) stroke=\(s.id.uuidString.prefix(8)) bbox=\(s.boundingBox) pts=\(s.points.count)")
        }
    }

    func handleGrowGestureStarted(origin: GrowOrigin) {
        cancelLasso()
        let prior = selectedStrokeIDs
        selectionBeforeGrow = prior

        let mode: GrowMode = {
            if let seedID = origin.initialStrokeID, prior.contains(seedID) {
                return .subtract
            }
            return .add
        }()
        let candidatePool: [Stroke] = (mode == .subtract)
            ? canvas.strokes.filter { prior.contains($0.id) }
            : canvas.strokes

        let session = GrowStrategy.start(origin: origin, mode: mode, candidatePool: candidatePool)
        growSession = session
        // Reflect the initial admission in the highlight layer so the user
        // immediately sees what's being captured.
        selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
        growthFrame = GrowFrame(
            radius: session.currentRadius,
            center: origin.anchor,
            includedStrokeIDs: session.includedStrokeIDs,
            nextCandidateID: session.nextCandidateID,
            isPaused: session.isPaused,
            mode: mode
        )
        startDisplayLink()
    }

    func handleGrowGestureEnded() {
        stopDisplayLink()
        if let session = growSession, let prior = selectionBeforeGrow {
            // Already mirrored in selectedStrokeIDs by ticks; recomputing from
            // the snapshot guarantees the canonical commit even if a tick was
            // skipped between the last frame and release.
            selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
        }
        growSession = nil
        growthFrame = nil
        selectionBeforeGrow = nil
    }

    /// Discards the active grow gesture and reverts the selection to what it
    /// was before the hold began (system cancellation, mode toggle, etc.).
    func handleGrowGestureCancelled() {
        stopDisplayLink()
        if let prior = selectionBeforeGrow {
            selectedStrokeIDs = prior
        }
        growSession = nil
        growthFrame = nil
        selectionBeforeGrow = nil
    }

    /// Combines the pre-gesture selection snapshot with the session's affected
    /// set. Add mode unions; subtract mode (added in a later step) will
    /// difference. Returns the set to assign to `selectedStrokeIDs`.
    private func applyGrowToSelection(prior: Set<UUID>, session: GrowSession) -> Set<UUID> {
        switch session.mode {
        case .add:      return prior.union(session.includedStrokeIDs)
        case .subtract: return prior.subtracting(session.includedStrokeIDs)
        }
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: DisplayLinkProxy(viewModel: self),
                                 selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTickTimestamp = CACurrentMediaTime()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayLinkTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(0, now - lastTickTimestamp)
        lastTickTimestamp = now
        guard let session = growSession, let prior = selectionBeforeGrow else { return }
        let frame = session.tick(deltaTime: dt)
        growthFrame = frame
        // Mirror the running session into the published selection so the
        // highlight layer paints captured strokes as they get admitted.
        selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
    }

    private func cancelLasso() {
        lassoPoints = []
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

    // MARK: - Color

    func setActiveColor(_ color: CodableColor, addToRecents: Bool) {
        canvas.activeColor = color
        if addToRecents {
            canvas.pushRecentColor(color)
        }
    }
}

/// CADisplayLink retains its target. Using a weak-ref proxy avoids a retain
/// cycle that would keep the view model alive for the lifetime of the link.
private final class DisplayLinkProxy {
    weak var viewModel: DrawingViewModel?
    init(viewModel: DrawingViewModel) { self.viewModel = viewModel }
    @objc func tick(_ link: CADisplayLink) { viewModel?.displayLinkTick(link) }
}
