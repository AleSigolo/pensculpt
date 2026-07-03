import XCTest
import SwiftUI
import PencilKit
@testable import PenSculpt

/// Hosts the real DrawingScreen and opens a document whose model
/// (canvas.strokes) is desynced from its visible ink (pkDrawing) — the
/// residue of the ghost-stroke bug (see the programmatic-echo guard in
/// CanvasView). Load must self-heal: the model is rebuilt from the visible
/// drawing and sculpt objects whose source ink no longer resolves are pruned.
@MainActor
final class DrawingScreenReconcileTests: XCTestCase {

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func makeStroke(at p: CGPoint) -> Stroke {
        Stroke(points: [
            StrokePoint(location: p, pressure: 1, tilt: 0, azimuth: 0,
                        timestamp: 0),
            StrokePoint(location: CGPoint(x: p.x + 40, y: p.y), pressure: 1,
                        tilt: 0, azimuth: 0, timestamp: 0.01),
        ])
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testCorruptedDocumentSelfHealsOnLoad() {
        // Visible ink: 2 strokes. Model: those 2 plus a ghost the visible
        // drawing no longer has — exactly what the pre-fix bug persisted.
        let visible = [makeStroke(at: CGPoint(x: 100, y: 100)),
                       makeStroke(at: CGPoint(x: 300, y: 300))]
        let ghost = makeStroke(at: CGPoint(x: 500, y: 500))
        var canvas = Canvas()
        (visible + [ghost]).forEach { canvas.addStroke($0) }
        let pk = PKDrawing(strokes: visible.map { StrokeConverter.toPKStroke($0) })
        let orphan = SculptObject(mesh: Mesh(), sourceStrokeIDs: [ghost.id])

        let canvasBox = Box(canvas)
        let dataBox = Box(pk.dataRepresentation())
        let objectsBox = Box([orphan])

        let screen = DrawingScreen(
            canvas: Binding(get: { canvasBox.value }, set: { canvasBox.value = $0 }),
            drawingData: Binding(get: { dataBox.value }, set: { dataBox.value = $0 }),
            sculptObjects: Binding(get: { objectsBox.value }, set: { objectsBox.value = $0 })
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.makeKeyAndVisible()
        pump(1.0)

        XCTAssertEqual(canvasBox.value.strokes.count, 2,
                       "load must rebuild the model from the 2 visible strokes (ghost dropped)")
        XCTAssertTrue(objectsBox.value.isEmpty,
                      "an object whose source ink is only ghost strokes must be pruned")
    }

    func testHealthyDocumentLoadsUntouched() {
        let strokes = [makeStroke(at: CGPoint(x: 100, y: 100)),
                       makeStroke(at: CGPoint(x: 300, y: 300))]
        var canvas = Canvas()
        strokes.forEach { canvas.addStroke($0) }
        let pk = PKDrawing(strokes: strokes.map { StrokeConverter.toPKStroke($0) })
        let object = SculptObject(mesh: Mesh(), sourceStrokeIDs: [strokes[0].id])
        let originalIDs = canvas.strokes.map(\.id)

        let canvasBox = Box(canvas)
        let dataBox = Box(pk.dataRepresentation())
        let objectsBox = Box([object])

        let screen = DrawingScreen(
            canvas: Binding(get: { canvasBox.value }, set: { canvasBox.value = $0 }),
            drawingData: Binding(get: { dataBox.value }, set: { dataBox.value = $0 }),
            sculptObjects: Binding(get: { objectsBox.value }, set: { objectsBox.value = $0 })
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.makeKeyAndVisible()
        pump(1.0)

        XCTAssertEqual(canvasBox.value.strokes.map(\.id), originalIDs,
                       "a parity-correct document must keep its stroke IDs (re-entry depends on them)")
        XCTAssertEqual(objectsBox.value.count, 1)
    }
}
