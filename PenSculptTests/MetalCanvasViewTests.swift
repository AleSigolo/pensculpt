import XCTest
import UIKit
@testable import PenSculpt

final class MetalCanvasViewTests: XCTestCase {

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

    // MARK: - Stale buffer flush on gesture began

    func testSinglePanBeganFlushesStaleCoalescedSamples() {
        let coordinator = MetalCanvasView.Coordinator()
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        // Simulate stale samples from prior gestures (taps, two-finger rotate/pinch)
        view.coalescedSamples.append((location: CGPoint(x: 100, y: 100), force: 0.5, maxForce: 1.0, timestamp: 0))
        view.coalescedSamples.append((location: CGPoint(x: 200, y: 200), force: 0.8, maxForce: 1.0, timestamp: 0))
        XCTAssertEqual(view.coalescedSamples.count, 2)

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockState = .began
        gesture.mockView = view

        coordinator.handleSinglePan(gesture)

        XCTAssertTrue(view.coalescedSamples.isEmpty,
                      "Stale coalesced samples should be cleared when single-finger gesture begins")
    }

    func testSinglePanChangedDoesNotPreFlush() {
        let coordinator = MetalCanvasView.Coordinator()
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        // Add a sample representing current drawing input
        view.coalescedSamples.append((location: CGPoint(x: 50, y: 50), force: 0.6, maxForce: 1.0, timestamp: 0))

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockState = .changed
        gesture.mockView = view

        // handleDraw will exit early (no renderer), so samples remain if pre-flush didn't run
        coordinator.handleSinglePan(gesture)

        XCTAssertEqual(view.coalescedSamples.count, 1,
                       "Pre-flush should only occur on .began, not .changed")
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
                       "Pre-flush should only occur on .began, not .ended")
    }

    func testBeganFlushWorksInDeformMode() {
        let coordinator = MetalCanvasView.Coordinator()
        coordinator.isDeformMode = true
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        view.coalescedSamples.append((location: CGPoint(x: 10, y: 10), force: 0.3, maxForce: 1.0, timestamp: 0))

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockState = .began
        gesture.mockView = view

        coordinator.handleSinglePan(gesture)

        XCTAssertTrue(view.coalescedSamples.isEmpty,
                      "Stale samples should be flushed on .began regardless of mode")
    }

    func testBeganFlushWorksInRotateMode() {
        let coordinator = MetalCanvasView.Coordinator()
        coordinator.isRotateMode = true
        let view = ForceMTKView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), device: nil)

        view.coalescedSamples.append((location: CGPoint(x: 10, y: 10), force: 0.3, maxForce: 1.0, timestamp: 0))

        let gesture = MockPanGestureRecognizer(target: nil, action: nil)
        gesture.mockState = .began
        gesture.mockView = view

        coordinator.handleSinglePan(gesture)

        XCTAssertTrue(view.coalescedSamples.isEmpty,
                      "Stale samples should be flushed on .began regardless of mode")
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
