import XCTest
import SwiftUI
import PencilKit
@testable import PenSculpt

/// End-to-end reproduction of the "Couldn't lift that selection" bug:
/// hosts the REAL DrawingScreen in a window and drives the real
/// select→edit seam (handleLassoCompleted → appMode = .edit → onChange
/// beginEditSession vs. Edit25DOverlay onAppear/startSession), which unit
/// tests previously bypassed.
@MainActor
final class LiftSelectionFlowTests: XCTestCase {

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func makeBlobStroke(center: CGPoint = CGPoint(x: 400, y: 400),
                                radius: CGFloat = 150) -> Stroke {
        let points = (0...36).map { i -> StrokePoint in
            let a = CGFloat(i) / 36 * 2 * .pi
            return StrokePoint(location: CGPoint(x: center.x + radius * cos(a),
                                                 y: center.y + radius * sin(a)),
                               pressure: 1, tilt: 0, azimuth: 0,
                               timestamp: TimeInterval(i) * 0.01)
        }
        return Stroke(points: points)
    }

    /// DrawingScreen owns its DrawingViewModel privately; the VM is a class,
    /// so the instance captured in the initial @State value is the same one
    /// the hosted view uses. Extract it via Mirror.
    private func extractVM(from screen: DrawingScreen) -> DrawingViewModel? {
        guard let state = Mirror(reflecting: screen).descendant("_vm") else { return nil }
        for child in Mirror(reflecting: state).children {
            if let vm = child.value as? DrawingViewModel { return vm }
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testLassoLiftFlowAppendsSculptObject() throws {
        let blob = makeBlobStroke()
        var canvas = Canvas()
        canvas.addStroke(blob)
        let pk = PKDrawing(strokes: [StrokeConverter.toPKStroke(blob)])

        let canvasBox = Box(canvas)
        let dataBox = Box(pk.dataRepresentation())
        let objectsBox = Box([SculptObject]())

        let screen = DrawingScreen(
            canvas: Binding(get: { canvasBox.value }, set: { canvasBox.value = $0 }),
            drawingData: Binding(get: { dataBox.value }, set: { dataBox.value = $0 }),
            sculptObjects: Binding(get: { objectsBox.value }, set: { objectsBox.value = $0 })
        )
        let vm = try XCTUnwrap(extractVM(from: screen), "could not extract DrawingViewModel")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.makeKeyAndVisible()
        pump(1.0)

        // PKCanvasView can re-report the programmatically loaded drawing via
        // its delegate in this harness (duplicating the blob in vm.canvas);
        // harmless here — the copies are geometrically identical and all
        // selected. Only require that the blob is present.
        XCTAssertGreaterThanOrEqual(vm.canvas.strokes.count, 1)

        // Real mode toggle (nav button action).
        vm.toggleMode()
        pump(0.3)
        XCTAssertEqual(vm.appMode, .select)

        // Real lasso completion path (SelectionView.endStroke calls this).
        let lasso = (0...36).map { i -> CGPoint in
            let a = CGFloat(i) / 36 * 2 * .pi
            return CGPoint(x: 400 + 250 * cos(a), y: 400 + 250 * sin(a))
        }
        vm.handleLassoCompleted(polygon: lasso)
        XCTAssertEqual(vm.appMode, .edit,
                       "lasso should select the blob and flip to edit mode")

        // Wait for inference to resolve one way or the other.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            pump(0.1)
            if !objectsBox.value.isEmpty { break }        // fresh lift succeeded
            if vm.appMode != .edit { break }              // onInferenceFailed exited the session
        }

        XCTAssertEqual(objectsBox.value.count, 1,
                       "fresh lift must append a SculptObject; empty means the onInferenceFailed toast path ran")
        XCTAssertEqual(vm.appMode, .edit,
                       "session should still be live, not bounced back to draw")
    }
}
