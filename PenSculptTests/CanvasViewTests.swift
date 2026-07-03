import XCTest
import PencilKit
import SwiftUI
@testable import PenSculpt

final class CanvasViewTests: XCTestCase {

    private func makePKStroke(at point: CGPoint) -> PKStroke {
        let points = [
            PKStrokePoint(location: point, timeOffset: 0,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 4)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    // MARK: - Programmatic-echo suppression (ghost-stroke bug)

    /// Opening a document loads pkDrawing programmatically; PKCanvasView
    /// re-reports it via canvasViewDrawingDidChange. That echo must NOT be
    /// treated as a user stroke: the count-jump branch would append a
    /// duplicate to the model, silently desyncing canvas.strokes from
    /// pkDrawing by index — every later erase then removes the wrong model
    /// stroke and leaves ghosts that selection/lift still see.
    @MainActor
    func testProgrammaticLoadEchoDoesNotReportACompletedStroke() {
        var boundDrawing = PKDrawing(strokes: [
            makePKStroke(at: CGPoint(x: 0, y: 0)),
            makePKStroke(at: CGPoint(x: 100, y: 100)),
        ])
        var completedCount = 0
        let view = CanvasView(
            drawing: Binding(get: { boundDrawing }, set: { boundDrawing = $0 }),
            selectedTool: .pen, strokeWidth: 5, strokeOpacity: 1,
            onStrokeCompleted: { _ in completedCount += 1 },
            onStrokeErased: { _ in XCTFail("echo must not report erases") },
            isInteractive: true, viewBridge: nil
        )
        let coordinator = view.makeCoordinator()
        let canvasView = PKCanvasView()
        // Programmatic set, as updateUIView does; the delegate echo can fire
        // during the assignment (flag window) or after (counts already reset).
        coordinator.setDrawingProgrammatically(boundDrawing, on: canvasView)
        coordinator.canvasViewDrawingDidChange(canvasView)

        XCTAssertEqual(completedCount, 0,
                       "a programmatic load echo appended a ghost stroke to the model")
    }

    @MainActor
    func testUserStrokeStillReportsCompletion() {
        var boundDrawing = PKDrawing()
        var completedCount = 0
        let view = CanvasView(
            drawing: Binding(get: { boundDrawing }, set: { boundDrawing = $0 }),
            selectedTool: .pen, strokeWidth: 5, strokeOpacity: 1,
            onStrokeCompleted: { _ in completedCount += 1 },
            onStrokeErased: { _ in XCTFail("no erase expected") },
            isInteractive: true, viewBridge: nil
        )
        let coordinator = view.makeCoordinator()
        let canvasView = PKCanvasView()
        // A user stroke: the canvas is ahead of the bound model by one.
        canvasView.drawing = PKDrawing(strokes: [makePKStroke(at: CGPoint(x: 10, y: 10))])
        coordinator.canvasViewDrawingDidChange(canvasView)

        XCTAssertEqual(completedCount, 1)
    }

    @MainActor
    func testUserEraseStillReportsRemovedIndices() {
        let s0 = makePKStroke(at: CGPoint(x: 0, y: 0))
        let s1 = makePKStroke(at: CGPoint(x: 100, y: 100))
        var boundDrawing = PKDrawing(strokes: [s0, s1])
        var erased: [[Int]] = []
        let view = CanvasView(
            drawing: Binding(get: { boundDrawing }, set: { boundDrawing = $0 }),
            selectedTool: .eraser, strokeWidth: 5, strokeOpacity: 1,
            onStrokeCompleted: { _ in XCTFail("no completion expected") },
            onStrokeErased: { erased.append($0) },
            isInteractive: true, viewBridge: nil
        )
        let coordinator = view.makeCoordinator()
        let canvasView = PKCanvasView()
        canvasView.drawing = boundDrawing
        coordinator.resetTracking(to: boundDrawing)
        // The user erases s0: the canvas is behind the bound model by one.
        canvasView.drawing = PKDrawing(strokes: [s1])
        coordinator.canvasViewDrawingDidChange(canvasView)

        XCTAssertEqual(erased, [[0]])
    }

    func testRemovedIndicesNoneRemoved() {
        let strokes = [
            makePKStroke(at: CGPoint(x: 0, y: 0)),
            makePKStroke(at: CGPoint(x: 100, y: 100)),
            makePKStroke(at: CGPoint(x: 200, y: 200))
        ]
        let result = CanvasView.removedStrokeIndices(previous: strokes, current: strokes)
        XCTAssertTrue(result.isEmpty)
    }

    func testRemovedIndicesSingleRemoved() {
        let s0 = makePKStroke(at: CGPoint(x: 0, y: 0))
        let s1 = makePKStroke(at: CGPoint(x: 100, y: 100))
        let s2 = makePKStroke(at: CGPoint(x: 200, y: 200))
        let result = CanvasView.removedStrokeIndices(
            previous: [s0, s1, s2],
            current: [s0, s2]
        )
        XCTAssertEqual(result, [1])
    }

    func testRemovedIndicesFirstRemoved() {
        let s0 = makePKStroke(at: CGPoint(x: 0, y: 0))
        let s1 = makePKStroke(at: CGPoint(x: 100, y: 100))
        let s2 = makePKStroke(at: CGPoint(x: 200, y: 200))
        let result = CanvasView.removedStrokeIndices(
            previous: [s0, s1, s2],
            current: [s1, s2]
        )
        XCTAssertEqual(result, [0])
    }

    func testRemovedIndicesLastRemoved() {
        let s0 = makePKStroke(at: CGPoint(x: 0, y: 0))
        let s1 = makePKStroke(at: CGPoint(x: 100, y: 100))
        let s2 = makePKStroke(at: CGPoint(x: 200, y: 200))
        let result = CanvasView.removedStrokeIndices(
            previous: [s0, s1, s2],
            current: [s0, s1]
        )
        XCTAssertEqual(result, [2])
    }

    func testRemovedIndicesMultipleRemoved() {
        let s0 = makePKStroke(at: CGPoint(x: 0, y: 0))
        let s1 = makePKStroke(at: CGPoint(x: 100, y: 100))
        let s2 = makePKStroke(at: CGPoint(x: 200, y: 200))
        let s3 = makePKStroke(at: CGPoint(x: 300, y: 300))
        let result = CanvasView.removedStrokeIndices(
            previous: [s0, s1, s2, s3],
            current: [s0, s3]
        )
        XCTAssertEqual(result, [1, 2])
    }

    func testRemovedIndicesAllRemoved() {
        let strokes = [
            makePKStroke(at: CGPoint(x: 0, y: 0)),
            makePKStroke(at: CGPoint(x: 100, y: 100))
        ]
        let result = CanvasView.removedStrokeIndices(previous: strokes, current: [])
        XCTAssertEqual(result, [0, 1])
    }

    func testRemovedIndicesBothEmpty() {
        let result = CanvasView.removedStrokeIndices(previous: [], current: [])
        XCTAssertTrue(result.isEmpty)
    }
}
