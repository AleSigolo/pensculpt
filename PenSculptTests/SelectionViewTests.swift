import XCTest
@testable import PenSculpt

final class SelectionViewTests: XCTestCase {

    private func makeSelectionView() -> SelectionView {
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        view.backgroundColor = .clear
        return view
    }

    // MARK: - Basic stroke lifecycle

    func testBeginStrokeSetsInitialPoint() {
        let view = makeSelectionView()
        view.beginStroke(displayPoint: CGPoint(x: 100, y: 200), targetPoint: CGPoint(x: 100, y: 286))

        XCTAssertEqual(view.displayPoints.count, 1)
        XCTAssertEqual(view.displayPoints[0], CGPoint(x: 100, y: 200))
        XCTAssertEqual(view.hitTestPoints.count, 1)
        XCTAssertEqual(view.hitTestPoints[0], CGPoint(x: 100, y: 286))
    }

    func testContinueStrokeAppendsPoints() {
        let view = makeSelectionView()
        view.beginStroke(displayPoint: CGPoint(x: 0, y: 0), targetPoint: CGPoint(x: 0, y: 0))
        view.continueStroke(displayPoint: CGPoint(x: 50, y: 50), targetPoint: CGPoint(x: 50, y: 136))
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 0), targetPoint: CGPoint(x: 100, y: 86))

        XCTAssertEqual(view.displayPoints.count, 3)
        XCTAssertEqual(view.hitTestPoints.count, 3)
    }

    func testEndStrokeClosesPathWhenMoreThan2Points() {
        let view = makeSelectionView()
        view.beginStroke(displayPoint: CGPoint(x: 0, y: 0), targetPoint: CGPoint(x: 0, y: 0))
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 0), targetPoint: CGPoint(x: 100, y: 0))
        view.continueStroke(displayPoint: CGPoint(x: 50, y: 100), targetPoint: CGPoint(x: 50, y: 100))
        view.endStroke()

        // Path should be closed: 3 original + 1 closing = 4
        XCTAssertEqual(view.displayPoints.count, 4)
        XCTAssertEqual(view.hitTestPoints.count, 4)
        // Last point should equal first point
        XCTAssertEqual(view.displayPoints.last, view.displayPoints.first)
        XCTAssertEqual(view.hitTestPoints.last, view.hitTestPoints.first)
        XCTAssertTrue(view.isClosed)
    }

    func testEndStrokeDiscardsWhenTooFewPoints() {
        let view = makeSelectionView()
        view.beginStroke(displayPoint: CGPoint(x: 0, y: 0), targetPoint: CGPoint(x: 0, y: 0))
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 0), targetPoint: CGPoint(x: 100, y: 0))
        view.endStroke()

        // Only 2 points — should be discarded
        XCTAssertTrue(view.displayPoints.isEmpty)
        XCTAssertTrue(view.hitTestPoints.isEmpty)
        XCTAssertFalse(view.isClosed)
    }

    func testEndStrokeDiscardsSinglePoint() {
        let view = makeSelectionView()
        view.beginStroke(displayPoint: CGPoint(x: 50, y: 50), targetPoint: CGPoint(x: 50, y: 50))
        view.endStroke()

        XCTAssertTrue(view.displayPoints.isEmpty)
        XCTAssertFalse(view.isClosed)
    }

    // MARK: - Clearing and restarting

    func testClearLasso() {
        let view = makeSelectionView()
        view.beginStroke(displayPoint: .zero, targetPoint: .zero)
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 100), targetPoint: CGPoint(x: 100, y: 100))
        view.continueStroke(displayPoint: CGPoint(x: 0, y: 100), targetPoint: CGPoint(x: 0, y: 100))
        view.endStroke()
        XCTAssertTrue(view.isClosed)

        view.clearLasso()

        XCTAssertTrue(view.displayPoints.isEmpty)
        XCTAssertTrue(view.hitTestPoints.isEmpty)
        XCTAssertFalse(view.isClosed)
    }

    func testNewStrokeAfterClosedClearsPrevious() {
        let view = makeSelectionView()
        // Draw and close a lasso
        view.beginStroke(displayPoint: CGPoint(x: 0, y: 0), targetPoint: CGPoint(x: 0, y: 0))
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 0), targetPoint: CGPoint(x: 100, y: 0))
        view.continueStroke(displayPoint: CGPoint(x: 50, y: 100), targetPoint: CGPoint(x: 50, y: 100))
        view.endStroke()
        XCTAssertEqual(view.displayPoints.count, 4)
        XCTAssertTrue(view.isClosed)

        // Start a new stroke — should clear the old one
        view.beginStroke(displayPoint: CGPoint(x: 500, y: 500), targetPoint: CGPoint(x: 500, y: 586))

        XCTAssertEqual(view.displayPoints.count, 1)
        XCTAssertEqual(view.displayPoints[0], CGPoint(x: 500, y: 500))
        XCTAssertEqual(view.hitTestPoints.count, 1)
        XCTAssertFalse(view.isClosed)
    }

    // MARK: - Display vs hit-test coordinate separation

    func testDisplayAndHitTestPointsAreIndependent() {
        let view = makeSelectionView()
        // Simulate offset between display and target coordinates
        view.beginStroke(displayPoint: CGPoint(x: 100, y: 100), targetPoint: CGPoint(x: 100, y: 186))
        view.continueStroke(displayPoint: CGPoint(x: 200, y: 100), targetPoint: CGPoint(x: 200, y: 186))
        view.continueStroke(displayPoint: CGPoint(x: 150, y: 200), targetPoint: CGPoint(x: 150, y: 286))
        view.endStroke()

        // Display points should be in view coordinates
        XCTAssertEqual(view.displayPoints[0].y, 100)
        XCTAssertEqual(view.displayPoints[1].y, 100)
        XCTAssertEqual(view.displayPoints[2].y, 200)

        // Hit-test points should be in target coordinates (offset by 86)
        XCTAssertEqual(view.hitTestPoints[0].y, 186)
        XCTAssertEqual(view.hitTestPoints[1].y, 186)
        XCTAssertEqual(view.hitTestPoints[2].y, 286)
    }

    func testWithoutTargetViewPointsMatch() {
        let view = makeSelectionView()
        view.targetView = nil

        // Without a target view, the touch handlers use self coordinates for both
        // We test via the extracted methods directly — both should get the same values
        view.beginStroke(displayPoint: CGPoint(x: 50, y: 50), targetPoint: CGPoint(x: 50, y: 50))
        view.continueStroke(displayPoint: CGPoint(x: 150, y: 50), targetPoint: CGPoint(x: 150, y: 50))
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 150), targetPoint: CGPoint(x: 100, y: 150))
        view.endStroke()

        for i in 0..<view.displayPoints.count {
            XCTAssertEqual(view.displayPoints[i], view.hitTestPoints[i])
        }
    }

    // MARK: - Completion callback

    func testCompletionCallbackReceivesHitTestPoints() {
        let view = makeSelectionView()
        var completedPoints: [CGPoint] = []

        // Set up a mock coordinator to capture the callback
        let overlay = SelectionOverlay(
            lassoPoints: .constant([]),
            onLassoCompleted: { completedPoints = $0 }
        )
        let coordinator = SelectionOverlay.Coordinator(overlay)
        view.coordinator = coordinator

        view.beginStroke(displayPoint: CGPoint(x: 0, y: 0), targetPoint: CGPoint(x: 0, y: 86))
        view.continueStroke(displayPoint: CGPoint(x: 100, y: 0), targetPoint: CGPoint(x: 100, y: 86))
        view.continueStroke(displayPoint: CGPoint(x: 50, y: 100), targetPoint: CGPoint(x: 50, y: 186))
        view.endStroke()

        // Callback should receive hit-test points (target coordinates), not display points
        XCTAssertEqual(completedPoints.count, 4)
        XCTAssertEqual(completedPoints[0].y, 86)
        XCTAssertEqual(completedPoints[2].y, 186)
    }

    func testNoCallbackWhenTooFewPoints() {
        let view = makeSelectionView()
        var callbackCalled = false

        let overlay = SelectionOverlay(
            lassoPoints: .constant([]),
            onLassoCompleted: { _ in callbackCalled = true }
        )
        let coordinator = SelectionOverlay.Coordinator(overlay)
        view.coordinator = coordinator

        view.beginStroke(displayPoint: CGPoint(x: 0, y: 0), targetPoint: CGPoint(x: 0, y: 0))
        view.endStroke()

        XCTAssertFalse(callbackCalled)
    }
}
