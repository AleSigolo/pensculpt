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
        vm.appMode = .select

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
        vm.appMode = .select

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

    // MARK: - Selection strategy

    func testDefaultStrategyIsLasso() {
        let vm = makeVM()
        XCTAssertEqual(vm.activeStrategy, .lasso)
    }

    func testActivateSmartStrategy() {
        let vm = makeVM()
        vm.activateSmartStrategy()
        XCTAssertEqual(vm.activeStrategy, .smart)
    }

    func testHandleSmartSelectCommittedSetsSelection() {
        let vm = makeVM()
        let s1 = makeStroke(at: CGPoint(x: 10, y: 10))
        let s2 = makeStroke(at: CGPoint(x: 500, y: 500))
        vm.addStroke(s1)
        vm.addStroke(s2)
        vm.appMode = .select

        vm.handleSmartSelectCommitted(strokeIDs: [s1.id])

        XCTAssertEqual(vm.selectedStrokeIDs, [s1.id])
    }

    func testToggleToDrawResetsStrategyToLasso() {
        let vm = makeVM()
        vm.toggleMode()                // → select
        vm.activateSmartStrategy()     // → smart
        vm.toggleMode()                // → draw
        XCTAssertEqual(vm.activeStrategy, .lasso)
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

    // MARK: - 2.5D edit mode

    private func makeVMWithStroke() -> (DrawingViewModel, Stroke) {
        let stroke = Stroke(points: [
            StrokePoint(location: CGPoint(x: 10, y: 10), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: 90, y: 90), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
        var canvas = Canvas(size: CGSize(width: 1024, height: 1366))
        canvas.addStroke(stroke)
        return (DrawingViewModel(canvas: canvas), stroke)
    }

    func testLassoCommitWithSelectionEntersEditMode() {
        let (vm, _) = makeVMWithStroke()
        vm.appMode = .select
        // Polygon fully surrounding the stroke.
        vm.handleLassoCompleted(polygon: [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)
        ])
        XCTAssertTrue(vm.hasSelection)
        XCTAssertEqual(vm.appMode, .edit)
    }

    func testLassoCommitWithEmptySelectionStaysInSelectMode() {
        let (vm, _) = makeVMWithStroke()
        vm.appMode = .select
        vm.handleLassoCompleted(polygon: [
            CGPoint(x: 500, y: 500), CGPoint(x: 510, y: 500), CGPoint(x: 510, y: 510)
        ])
        XCTAssertFalse(vm.hasSelection)
        XCTAssertEqual(vm.appMode, .select)
    }

    func testSmartSelectCommitEntersEditMode() {
        let (vm, stroke) = makeVMWithStroke()
        vm.appMode = .select
        vm.handleSmartSelectCommitted(strokeIDs: [stroke.id])
        XCTAssertEqual(vm.appMode, .edit)
    }

    func testExitEditModeResetsSelection() {
        let (vm, stroke) = makeVMWithStroke()
        vm.appMode = .select
        vm.handleSmartSelectCommitted(strokeIDs: [stroke.id])
        vm.exitEditMode()
        XCTAssertEqual(vm.appMode, .draw)
        XCTAssertFalse(vm.hasSelection)
        XCTAssertTrue(vm.lassoPoints.isEmpty)
        XCTAssertEqual(vm.activeStrategy, .lasso)
    }

    func testToggleModeIsIgnoredWhileEditing() {
        let (vm, stroke) = makeVMWithStroke()
        vm.appMode = .select
        vm.handleSmartSelectCommitted(strokeIDs: [stroke.id])
        vm.toggleMode()
        XCTAssertEqual(vm.appMode, .edit)
    }

    func testLassoCommitFromDrawModeDoesNotEnterEdit() {
        let (vm, _) = makeVMWithStroke()
        // appMode stays .draw: selection commits must be no-ops outside .select.
        vm.handleLassoCompleted(polygon: [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)
        ])
        XCTAssertEqual(vm.appMode, .draw)
        XCTAssertFalse(vm.hasSelection)
    }

    func testSmartSelectCommitFromDrawModeDoesNotEnterEdit() {
        let (vm, stroke) = makeVMWithStroke()
        vm.handleSmartSelectCommitted(strokeIDs: [stroke.id])
        XCTAssertEqual(vm.appMode, .draw)
        XCTAssertFalse(vm.hasSelection)
    }

    func testPencilDoubleTapIgnoredInEditMode() {
        let (vm, stroke) = makeVMWithStroke()
        vm.appMode = .select
        vm.handleSmartSelectCommitted(strokeIDs: [stroke.id])
        XCTAssertEqual(vm.appMode, .edit)

        vm.handlePencilDoubleTap()
        XCTAssertEqual(vm.selectedTool, .pen, "Double-tap should be ignored in edit mode")
    }
}

/// Pins DrawingScreen.parityInsertionIndex: restored (unlifted) PK strokes
/// must land where the original stroke will sit once the still-hidden
/// (lifted) strokes leave the model at commit, keeping canvas.strokes and
/// pkDrawing.strokes parallel arrays back in draw mode.
final class EditSessionParityTests: XCTestCase {

    /// Restores `unlifted` (original indices) into `kept`, mirroring
    /// handleSourceStrokesLifted's insertion loop over string stand-ins.
    private func restore(unlifted: [Int], stillHidden: [Int], into kept: [String]) -> [String] {
        var strokes = kept
        for original in unlifted.sorted() {
            let idx = DrawingScreen.parityInsertionIndex(originalIndex: original,
                                                         stillHiddenOriginalIndices: stillHidden)
            strokes.insert("p\(original)", at: min(idx, strokes.count))
        }
        return strokes
    }

    func testMixedLiftedAndUnliftedRestoresParityOrder() {
        // Strokes s0–s4, selection {s1, s3}: s1 lifts (stays hidden), s3
        // doesn't. After commit removes s1 from the model, canvas is
        // [s0, s2, s3, s4] — pkDrawing must match, not [p0, p2, p4, p3].
        XCTAssertEqual(DrawingScreen.parityInsertionIndex(originalIndex: 3,
                                                          stillHiddenOriginalIndices: [1]), 2)
        let restored = restore(unlifted: [3], stillHidden: [1], into: ["p0", "p2", "p4"])
        XCTAssertEqual(restored, ["p0", "p2", "p3", "p4"])
    }

    func testAllUnliftedRestoresOriginalOrder() {
        // Selection {s1, s3}, nothing lifts: full reconstruction.
        let restored = restore(unlifted: [1, 3], stillHidden: [], into: ["p0", "p2", "p4"])
        XCTAssertEqual(restored, ["p0", "p1", "p2", "p3", "p4"])
    }

    func testUnliftedBelowLiftedIsUnshifted() {
        // Selection {s1, s3}: s3 lifts, s1 doesn't. No hidden stroke precedes
        // s1, so it returns to its original position.
        XCTAssertEqual(DrawingScreen.parityInsertionIndex(originalIndex: 1,
                                                          stillHiddenOriginalIndices: [3]), 1)
        let restored = restore(unlifted: [1], stillHidden: [3], into: ["p0", "p2", "p4"])
        XCTAssertEqual(restored, ["p0", "p1", "p2", "p4"])
    }
}
