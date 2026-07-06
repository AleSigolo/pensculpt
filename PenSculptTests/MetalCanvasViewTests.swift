import XCTest
import UIKit
import Metal
@testable import PenSculpt

final class MetalCanvasViewTests: XCTestCase {

    // MARK: - Force → ink width (manual check 3: session ink drew hairline)

    /// Typical Apple Pencil writing force is 0.3–1.0 while
    /// maximumPossibleForce is ~4.17. Normalizing by the maximum parked all
    /// real strokes at the bottom of the curve: session ink rendered at
    /// 15–25% of the brush width and light passages vanished entirely
    /// (0.05 × brush ≈ 0.4pt). The curve must stay solid at zero force,
    /// sit at the brush width for an average (1.0) touch, and cap gently.
    func testPressureWidthStaysSolidAcrossTheRealForceRange() {
        let brush: Float = 8
        let cases: [(force: CGFloat, minFactor: Float, maxFactor: Float)] = [
            (0.0, 0.6, 0.85),   // stroke tails / feather touches: still solid
            (0.5, 0.8, 1.0),    // light writing
            (1.0, 0.95, 1.05),  // Apple's "average touch" == brush width
            (4.17, 1.3, 1.7),   // pressing hard: gentle cap, not 4×
        ]
        for c in cases {
            let w = MetalCanvasView.pressureWidth(force: c.force, maxForce: 4.17,
                                                  brushSize: brush)
            XCTAssertGreaterThanOrEqual(w, brush * c.minFactor, "force \(c.force)")
            XCTAssertLessThanOrEqual(w, brush * c.maxFactor, "force \(c.force)")
        }
    }

    func testPressureWidthWithoutForceHardwareIsTheBrushWidth() {
        // Finger / simulator: maxForce 0 means no force stream — constant width.
        XCTAssertEqual(MetalCanvasView.pressureWidth(force: 0, maxForce: 0,
                                                     brushSize: 6), 6)
    }

    // MARK: - ForceMTKView buffer tests

    func testCoalescedSamplesStartEmpty() {
        let view = ForceMTKView(frame: .zero, device: nil)
        XCTAssertTrue(view.coalescedSamples.isEmpty)
    }

    func testCoalescedSamplesAccumulate() {
        let view = ForceMTKView(frame: .zero, device: nil)
        view.coalescedSamples.append((location: CGPoint(x: 10, y: 20), force: 0.5, maxForce: 1.0, timestamp: 0))
        view.coalescedSamples.append((location: CGPoint(x: 30, y: 40), force: 0.8, maxForce: 1.0, timestamp: 0))
        XCTAssertEqual(view.coalescedSamples.count, 2)
    }

    func testCoalescedSamplesClearRemovesAll() {
        let view = ForceMTKView(frame: .zero, device: nil)
        view.coalescedSamples.append((location: .zero, force: 0.5, maxForce: 1.0, timestamp: 0))
        view.coalescedSamples.append((location: .zero, force: 0.8, maxForce: 1.0, timestamp: 0))
        view.coalescedSamples.removeAll()
        XCTAssertTrue(view.coalescedSamples.isEmpty)
    }

    // MARK: - Stale buffer flush at touch-down

    func testTouchDownFlushesStaleSamplesButKeepsNewStrokeHead() {
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        // Simulate stale samples from prior gestures (taps, two-finger rotate/pinch)
        view.coalescedSamples.append((location: CGPoint(x: 100, y: 100), force: 0.5, maxForce: 1.0, timestamp: 0))
        view.coalescedSamples.append((location: CGPoint(x: 200, y: 200), force: 0.8, maxForce: 1.0, timestamp: 0))
        XCTAssertEqual(view.coalescedSamples.count, 2)

        let touch = MockTouch()
        touch.mockLocation = CGPoint(x: 10, y: 20)
        view.touchesBegan([touch], with: nil)

        // Stale samples from the previous sequence are gone; the new touch's
        // own first sample — the stroke head — is buffered, not discarded.
        XCTAssertEqual(view.coalescedSamples.count, 1,
                       "Touch-down should flush prior-sequence samples and buffer the new head")
        XCTAssertEqual(view.coalescedSamples[0].location, CGPoint(x: 10, y: 20))
        XCTAssertEqual(view.lastTouchDownLocation, CGPoint(x: 10, y: 20))
        XCTAssertFalse(view.lastTouchWasPencil)
    }

    func testSinglePanChangedDoesNotPreFlush() {
        let coordinator = MetalCanvasView.Coordinator()
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        // Add a sample representing current drawing input
        view.coalescedSamples.append((location: CGPoint(x: 50, y: 50), force: 0.6, maxForce: 1.0, timestamp: 0))

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockState = .changed
        gesture.mockView = view

        // handleDraw will exit early (no renderer), so samples remain untouched
        coordinator.handleSinglePan(gesture)

        XCTAssertEqual(view.coalescedSamples.count, 1,
                       "The gesture handler must not flush buffered samples on .changed")
    }

    func testSinglePanEndedDoesNotPreFlush() {
        let coordinator = MetalCanvasView.Coordinator()
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        view.coalescedSamples.append((location: CGPoint(x: 50, y: 50), force: 0.6, maxForce: 1.0, timestamp: 0))

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockState = .ended
        gesture.mockView = view

        coordinator.handleSinglePan(gesture)

        // handleDraw's .ended branch clears the buffer too, but only after processing.
        // Without a renderer, handleDraw exits early, leaving samples untouched.
        XCTAssertEqual(view.coalescedSamples.count, 1,
                       "The gesture handler must not flush buffered samples on .ended before processing")
    }

    func testTouchDownRecordsPencilPointer() {
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)
        let touch = MockTouch()
        touch.mockType = .pencil
        view.touchesBegan([touch], with: nil)
        XCTAssertTrue(view.lastTouchWasPencil)
    }

    func testSinglePanBeganPreservesStrokeHeadInAllModes() {
        // The flush moved to touchesBegan; the recognizer's .began must never
        // discard the stroke head buffered between touch-down and recognition.
        for (rotate, deform) in [(false, false), (true, false), (false, true)] {
            let coordinator = MetalCanvasView.Coordinator()
            coordinator.isRotateMode = rotate
            coordinator.isDeformMode = deform
            let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

            view.coalescedSamples.append((location: CGPoint(x: 10, y: 10), force: 0.3, maxForce: 1.0, timestamp: 0))

            let gesture = MockPanGestureRecognizer(target: nil, action: nil)
            gesture.mockState = .began
            gesture.mockView = view

            coordinator.handleSinglePan(gesture)

            XCTAssertEqual(view.coalescedSamples.count, 1,
                           "Stroke head must survive recognizer .began (rotate: \(rotate), deform: \(deform))")
        }
    }

    // MARK: - Edit-session routing

    func testEditSessionOffMeshPencilDragCapturesCanvasStroke() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available in this environment")
        }
        let renderer = try XCTUnwrap(SculptRenderer(device: device))
        let coordinator = MetalCanvasView.Coordinator()
        coordinator.renderer = renderer
        coordinator.isEditSession = true

        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)
        view.lastTouchWasPencil = true
        view.lastTouchDownLocation = CGPoint(x: 10, y: 10)

        var completed: Stroke?
        coordinator.onCanvasStrokeCompleted = { completed = $0 }

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockView = view

        // No sculpt objects → hitTest returns nil → the pencil drag starts
        // off-mesh and must classify as .drawOnCanvas. The head samples
        // buffered between touch-down and pan recognition must survive.
        view.coalescedSamples.append((location: CGPoint(x: 10, y: 10), force: 0.5, maxForce: 1.0, timestamp: 100.00))
        view.coalescedSamples.append((location: CGPoint(x: 12, y: 11), force: 0.5, maxForce: 1.0, timestamp: 100.01))
        gesture.mockState = .began
        coordinator.handleSinglePan(gesture)

        XCTAssertEqual(renderer.currentCanvasStrokePoints.count, 2,
                       "The stroke head buffered before .began must be captured, not discarded")
        XCTAssertEqual(renderer.currentCanvasStrokePoints.first, SIMD3<Float>(10, -10, 0))

        view.coalescedSamples.append((location: CGPoint(x: 20, y: 15), force: 0.6, maxForce: 1.0, timestamp: 100.02))
        gesture.mockState = .changed
        coordinator.handleSinglePan(gesture)
        XCTAssertEqual(renderer.currentCanvasStrokePoints.count, 3)

        gesture.mockState = .ended
        coordinator.handleSinglePan(gesture)

        let stroke = try XCTUnwrap(completed, "Ending the drag must fire onCanvasStrokeCompleted")
        XCTAssertEqual(stroke.points.count, 3)
        XCTAssertEqual(stroke.points[0].location, CGPoint(x: 10, y: 10),
                       "The first buffered sample must survive as the committed stroke's head")
        XCTAssertEqual(stroke.points[0].timestamp, 0, "Timestamps must be t0-relative")
        XCTAssertEqual(stroke.points[2].timestamp, 0.02, accuracy: 1e-6)
        XCTAssertTrue(renderer.currentCanvasStrokePoints.isEmpty,
                      "Live preview points must be cleared on gesture end")
        XCTAssertTrue(renderer.currentCanvasStrokeWidths.isEmpty,
                      "Live preview widths must be cleared on gesture end")
    }

    func testEditSessionDragActionLatchIgnoresMidDragModeChange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available in this environment")
        }
        let renderer = try XCTUnwrap(SculptRenderer(device: device))
        let coordinator = MetalCanvasView.Coordinator()
        coordinator.renderer = renderer
        coordinator.isEditSession = true

        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)
        view.lastTouchWasPencil = true
        view.lastTouchDownLocation = CGPoint(x: 10, y: 10)

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockView = view

        // Classified once at .began: pencil, off-mesh → .drawOnCanvas.
        view.coalescedSamples.append((location: CGPoint(x: 10, y: 10), force: 0.5, maxForce: 1.0, timestamp: 0))
        gesture.mockState = .began
        coordinator.handleSinglePan(gesture)
        XCTAssertEqual(renderer.currentCanvasStrokePoints.count, 1)

        // Mid-drag mode flip must NOT reclassify the latched action:
        // the stroke keeps accumulating instead of switching to rotate.
        coordinator.isRotateMode = true
        view.coalescedSamples.append((location: CGPoint(x: 20, y: 20), force: 0.5, maxForce: 1.0, timestamp: 0.01))
        gesture.mockState = .changed
        coordinator.handleSinglePan(gesture)
        XCTAssertEqual(renderer.currentCanvasStrokePoints.count, 2,
                       "Latched .drawOnCanvas action must keep accumulating despite mid-drag mode change")

        gesture.mockState = .ended
        coordinator.handleSinglePan(gesture)
        XCTAssertTrue(renderer.currentCanvasStrokePoints.isEmpty)
    }

    // MARK: - Simultaneous gesture recognition

    func testSimultaneousRecognitionForPinchAndRotation() {
        let coordinator = MetalCanvasView.Coordinator()

        let pinch = UIPinchGestureRecognizer()
        let rotation = UIRotationGestureRecognizer()

        XCTAssertTrue(coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: rotation))
        XCTAssertTrue(coordinator.gestureRecognizer(rotation, shouldRecognizeSimultaneouslyWith: pinch))
    }

    func testSimultaneousRecognitionForTwoFingerPanAndPinch() {
        let coordinator = MetalCanvasView.Coordinator()

        let twoFingerPan = UIPanGestureRecognizer()
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer()

        XCTAssertTrue(coordinator.gestureRecognizer(twoFingerPan, shouldRecognizeSimultaneouslyWith: pinch))
    }

    func testNoSimultaneousRecognitionForSingleFingerPanWithPinch() {
        let coordinator = MetalCanvasView.Coordinator()

        let singlePan = UIPanGestureRecognizer()
        singlePan.minimumNumberOfTouches = 1
        singlePan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer()

        XCTAssertFalse(coordinator.gestureRecognizer(singlePan, shouldRecognizeSimultaneouslyWith: pinch))
    }

    func testNoSimultaneousRecognitionForTwoSingleFingerPans() {
        let coordinator = MetalCanvasView.Coordinator()

        let pan1 = UIPanGestureRecognizer()
        pan1.minimumNumberOfTouches = 1
        pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer()
        pan2.minimumNumberOfTouches = 1
        pan2.maximumNumberOfTouches = 1

        XCTAssertFalse(coordinator.gestureRecognizer(pan1, shouldRecognizeSimultaneouslyWith: pan2))
    }

    func testSimultaneousRecognitionForAllThreeTwoFingerGestures() {
        let coordinator = MetalCanvasView.Coordinator()

        let twoFingerPan = UIPanGestureRecognizer()
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer()
        let rotation = UIRotationGestureRecognizer()

        // All pairs should be simultaneous
        XCTAssertTrue(coordinator.gestureRecognizer(twoFingerPan, shouldRecognizeSimultaneouslyWith: pinch))
        XCTAssertTrue(coordinator.gestureRecognizer(twoFingerPan, shouldRecognizeSimultaneouslyWith: rotation))
        XCTAssertTrue(coordinator.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: rotation))
    }
}

// MARK: - Mock gesture recognizer

private class MockPanGestureRecognizer: UIPanGestureRecognizer {
    var mockState: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }

    var mockView: UIView?
    override var view: UIView? { mockView }
}

// MARK: - Mock touch

private class MockTouch: UITouch {
    var mockLocation: CGPoint = .zero
    var mockType: UITouch.TouchType = .direct
    override func location(in view: UIView?) -> CGPoint { mockLocation }
    override var type: UITouch.TouchType { mockType }
    override var force: CGFloat { 0.5 }
    override var maximumPossibleForce: CGFloat { 1.0 }
    override var timestamp: TimeInterval { 42 }
}
