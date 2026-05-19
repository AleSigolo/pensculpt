import XCTest
@testable import PenSculpt

final class DrawingViewModelTests: XCTestCase {

    private func makeVM() -> DrawingViewModel {
        DrawingViewModel(canvas: Canvas())
    }

    private func makeStroke(at point: CGPoint = CGPoint(x: 50, y: 50)) -> Stroke {
        Stroke(points: [
            StrokePoint(location: point, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: point.x + 10, y: point.y + 10),
                        pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
    }

    // MARK: - Mode switching

    func testInitialModeIsDraw() {
        let vm = makeVM()
        XCTAssertEqual(vm.appMode, .draw)
    }

    func testToggleModeToSelect() {
        let vm = makeVM()
        vm.toggleMode()
        XCTAssertEqual(vm.appMode, .select)
    }

    func testToggleModeBackToDraw() {
        let vm = makeVM()
        vm.toggleMode() // → select
        vm.toggleMode() // → draw
        XCTAssertEqual(vm.appMode, .draw)
    }

    func testToggleToDrawClearsSelection() {
        let vm = makeVM()
        let stroke = makeStroke()
        vm.addStroke(stroke)
        vm.selectedStrokeIDs = [stroke.id]
        vm.lassoPoints = [.zero, CGPoint(x: 100, y: 100)]

        vm.toggleMode() // → select
        vm.toggleMode() // → draw

        XCTAssertTrue(vm.selectedStrokeIDs.isEmpty)
        XCTAssertTrue(vm.lassoPoints.isEmpty)
    }

    // MARK: - Pencil double-tap

    func testDoubleTapTogglesToEraser() {
        let vm = makeVM()
        XCTAssertEqual(vm.selectedTool, .pen)

        vm.handlePencilDoubleTap()
        XCTAssertEqual(vm.selectedTool, .eraser)
    }

    func testDoubleTapTogglesToPen() {
        let vm = makeVM()
        vm.selectedTool = .eraser

        vm.handlePencilDoubleTap()
        XCTAssertEqual(vm.selectedTool, .pen)
    }

    func testDoubleTapRemembersLastEraserType() {
        let vm = makeVM()
        vm.selectedTool = .pixelEraser

        vm.handlePencilDoubleTap() // → pen
        XCTAssertEqual(vm.selectedTool, .pen)

        vm.handlePencilDoubleTap() // → pixelEraser (last used)
        XCTAssertEqual(vm.selectedTool, .pixelEraser)
    }

    func testDoubleTapIgnoredInSelectMode() {
        let vm = makeVM()
        vm.appMode = .select

        vm.handlePencilDoubleTap()
        XCTAssertEqual(vm.selectedTool, .pen, "Double-tap should be ignored in select mode")
    }

    // MARK: - Tool change tracking

    func testSettingEraserTracksLastType() {
        let vm = makeVM()
        vm.selectedTool = .pixelEraser
        XCTAssertEqual(vm.lastEraserType, .pixelEraser)
    }

    func testSettingPenDoesNotResetLastEraser() {
        let vm = makeVM()
        vm.selectedTool = .pixelEraser
        vm.selectedTool = .pen
        XCTAssertEqual(vm.lastEraserType, .pixelEraser)
    }

    // MARK: - Selection

    func testHandleLassoCompletedSelectsStrokes() {
        let vm = makeVM()
        let stroke = makeStroke(at: CGPoint(x: 50, y: 50))
        vm.addStroke(stroke)

        let polygon = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0)
        ]
        vm.handleLassoCompleted(polygon: polygon)

        XCTAssertTrue(vm.selectedStrokeIDs.contains(stroke.id))
    }

    func testHandleLassoCompletedMissesOutsideStrokes() {
        let vm = makeVM()
        let stroke = makeStroke(at: CGPoint(x: 500, y: 500))
        vm.addStroke(stroke)

        let polygon = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0)
        ]
        vm.handleLassoCompleted(polygon: polygon)

        XCTAssertTrue(vm.selectedStrokeIDs.isEmpty)
    }

    func testSelectedStrokes() {
        let vm = makeVM()
        let s1 = makeStroke(at: CGPoint(x: 10, y: 10))
        let s2 = makeStroke(at: CGPoint(x: 500, y: 500))
        vm.addStroke(s1)
        vm.addStroke(s2)
        vm.selectedStrokeIDs = [s1.id]

        XCTAssertEqual(vm.selectedStrokes.count, 1)
        XCTAssertEqual(vm.selectedStrokes.first?.id, s1.id)
    }

    func testHasSelection() {
        let vm = makeVM()
        XCTAssertFalse(vm.hasSelection)

        vm.selectedStrokeIDs = [UUID()]
        XCTAssertTrue(vm.hasSelection)
    }

    // MARK: - Stroke mutations

    func testAddStroke() {
        let vm = makeVM()
        let stroke = makeStroke()
        vm.addStroke(stroke)
        XCTAssertEqual(vm.canvas.strokes.count, 1)
    }

    func testRemoveStroke() {
        let vm = makeVM()
        let stroke = makeStroke()
        vm.addStroke(stroke)
        vm.removeStroke(id: stroke.id)
        XCTAssertTrue(vm.canvas.strokes.isEmpty)
    }

    func testClearStrokes() {
        let vm = makeVM()
        vm.addStroke(makeStroke())
        vm.addStroke(makeStroke())
        vm.clearStrokes()
        XCTAssertTrue(vm.canvas.strokes.isEmpty)
    }

    // MARK: - Color

    func testSetActiveColorPresetDoesNotTouchRecents() {
        let vm = makeVM()
        let red = CodableColor(red: 1, green: 0, blue: 0, alpha: 1)
        vm.setActiveColor(red, addToRecents: false)
        XCTAssertEqual(vm.canvas.activeColor, red)
        XCTAssertTrue(vm.canvas.recentColors.isEmpty)
    }

    func testSetActiveColorCustomPushesRecents() {
        let vm = makeVM()
        let teal = CodableColor(red: 0, green: 0.5, blue: 0.5, alpha: 1)
        vm.setActiveColor(teal, addToRecents: true)
        XCTAssertEqual(vm.canvas.activeColor, teal)
        XCTAssertEqual(vm.canvas.recentColors, [teal])
    }

    func testSetActiveColorCustomDedupesRecents() {
        let vm = makeVM()
        let a = CodableColor(red: 1, green: 0, blue: 0, alpha: 1)
        let b = CodableColor(red: 0, green: 1, blue: 0, alpha: 1)
        vm.setActiveColor(a, addToRecents: true)
        vm.setActiveColor(b, addToRecents: true)
        vm.setActiveColor(a, addToRecents: true)
        XCTAssertEqual(vm.canvas.recentColors, [a, b])
    }

    // MARK: - Grow selection lifecycle

    func testGrowGestureStartCreatesSession() {
        let vm = makeVM()
        let id = UUID()
        let s = Stroke(id: id, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [s]
        vm.handleGrowGestureStarted(origin: .stroke(strokeID: id, anchor: .zero))
        XCTAssertNotNil(vm.growSession)
        XCTAssertNotNil(vm.growthFrame)
    }

    func testGrowGestureEndCommitsSelection() {
        let vm = makeVM()
        let id = UUID()
        let s = Stroke(id: id, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [s]
        vm.handleGrowGestureStarted(origin: .stroke(strokeID: id, anchor: .zero))
        vm.handleGrowGestureEnded()
        XCTAssertNil(vm.growSession)
        XCTAssertNil(vm.growthFrame)
        XCTAssertEqual(vm.selectedStrokeIDs, [id])
    }

    func testGrowGestureStartReflectsAdmittedStrokesImmediately() {
        // The user must see what they're capturing during the hold — the
        // initial admission should be mirrored into selectedStrokeIDs so the
        // SelectionHighlight layer paints the seed stroke right away.
        let vm = makeVM()
        let id = UUID()
        let s = Stroke(id: id, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [s]
        vm.handleGrowGestureStarted(origin: .stroke(strokeID: id, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [id])
    }

    func testGrowGestureCancelRevertsSelection() {
        // Pre-existing selection is restored when the gesture is cancelled.
        let vm = makeVM()
        let priorID = UUID()
        let prior = Stroke(id: priorID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let growID = UUID()
        let target = Stroke(id: growID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [prior, target]
        vm.selectedStrokeIDs = [priorID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: growID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [priorID, growID], "during hold, selection mirrors prior ∪ grow")

        vm.handleGrowGestureCancelled()
        XCTAssertNil(vm.growSession)
        XCTAssertNil(vm.growthFrame)
        XCTAssertEqual(vm.selectedStrokeIDs, [priorID], "cancel must revert to the pre-grow selection")
    }

    func testToggleModeCancelsActiveGrow() {
        let vm = makeVM()
        let id = UUID()
        let s = Stroke(id: id, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [s]
        vm.appMode = .select
        vm.handleGrowGestureStarted(origin: .stroke(strokeID: id, anchor: .zero))
        // toggleMode out of .select while a grow is in flight should discard it
        vm.toggleMode()
        XCTAssertEqual(vm.appMode, .draw)
        XCTAssertNil(vm.growSession)
        XCTAssertNil(vm.growthFrame)
    }

    func testGrowAddUnionsWithPriorSelection() {
        let vm = makeVM()
        let priorID = UUID()
        let prior = Stroke(id: priorID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let growID = UUID()
        let target = Stroke(id: growID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [prior, target]
        vm.selectedStrokeIDs = [priorID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: growID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [priorID, growID],
                       "during hold, selection mirrors prior ∪ grown")

        vm.handleGrowGestureEnded()
        XCTAssertEqual(vm.selectedStrokeIDs, [priorID, growID],
                       "finalize commits prior ∪ grown")
    }

    func testGrowSubtractRemovesSeedFromSelection() {
        // Long-press on an already-selected stroke must subtract: the seed
        // comes out of the selection immediately.
        let vm = makeVM()
        let keepID = UUID()
        let keep = Stroke(id: keepID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let removeID = UUID()
        let remove = Stroke(id: removeID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [keep, remove]
        vm.selectedStrokeIDs = [keepID, removeID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: removeID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [keepID],
                       "subtract removes the seed from the live selection")

        vm.handleGrowGestureEnded()
        XCTAssertEqual(vm.selectedStrokeIDs, [keepID],
                       "finalize commits the difference")
    }

    func testGrowSubtractRestrictsPoolToSelected() {
        // A non-selected stroke between the seed and another selected one
        // must NOT block or be touched by the subtract halo.
        let vm = makeVM()
        let aID = UUID()
        let bID = UUID()
        let outsiderID = UUID()
        let a = Stroke(id: aID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let outsider = Stroke(id: outsiderID, points: [
            StrokePoint(location: CGPoint(x: 5, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let b = Stroke(id: bID, points: [
            StrokePoint(location: CGPoint(x: 10, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [a, outsider, b]
        vm.selectedStrokeIDs = [aID, bID]  // outsider is NOT selected

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: aID, anchor: .zero))
        guard let session = vm.growSession else {
            return XCTFail("Session not created")
        }
        XCTAssertEqual(session.mode, .subtract)
        XCTAssertEqual(Set(session.candidatePool.map { $0.id }), [aID, bID],
                       "candidatePool must exclude non-selected strokes")
    }

    func testGrowAddOnEmptySpaceWithPriorSelection() {
        // Long-press on empty space with prior selection → add mode (not
        // subtract, since origin has no initialStrokeID).
        let vm = makeVM()
        let priorID = UUID()
        let prior = Stroke(id: priorID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [prior]
        vm.selectedStrokeIDs = [priorID]

        vm.handleGrowGestureStarted(origin: .point(.zero))
        XCTAssertEqual(vm.growSession?.mode, .add,
                       "empty-space origin must be add mode regardless of prior selection")
        XCTAssertTrue(vm.selectedStrokeIDs.contains(priorID),
                      "prior selection must be preserved during the hold")
    }

    func testGrowSubtractCancelRevertsToPriorSelection() {
        let vm = makeVM()
        let aID = UUID()
        let bID = UUID()
        let a = Stroke(id: aID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let b = Stroke(id: bID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [a, b]
        vm.selectedStrokeIDs = [aID, bID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: aID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [bID], "seed removed during hold")

        vm.handleGrowGestureCancelled()
        XCTAssertEqual(vm.selectedStrokeIDs, [aID, bID],
                       "cancel restores the full pre-grow selection")
    }
}
