import XCTest
import PencilKit
@testable import PenSculpt

final class LassoSelectionTests: XCTestCase {

    // MARK: - Algorithm tests

    func testPointInPolygon() {
        let square = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 0, y: 0)
        ]
        XCTAssertTrue(LassoSelection.contains(CGPoint(x: 50, y: 50), in: square))
        XCTAssertFalse(LassoSelection.contains(CGPoint(x: 150, y: 50), in: square))
        XCTAssertFalse(LassoSelection.contains(CGPoint(x: 50, y: 150), in: square))
    }

    func testStrokeSelectionThreshold() {
        let points = (0..<10).map {
            StrokePoint(location: CGPoint(x: CGFloat($0) * 10, y: 50),
                        pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        }
        let stroke = Stroke(points: points)

        // 5 of 10 points inside (50%) → selected
        let halfPolygon = [
            CGPoint(x: -1, y: 0), CGPoint(x: 46, y: 0),
            CGPoint(x: 46, y: 100), CGPoint(x: -1, y: 100), CGPoint(x: -1, y: 0)
        ]
        XCTAssertTrue(LassoSelection.isStrokeSelected(stroke, by: halfPolygon))

        // 4 of 10 points inside (40%) → not selected
        let smallPolygon = [
            CGPoint(x: -1, y: 0), CGPoint(x: 36, y: 0),
            CGPoint(x: 36, y: 100), CGPoint(x: -1, y: 100), CGPoint(x: -1, y: 0)
        ]
        XCTAssertFalse(LassoSelection.isStrokeSelected(stroke, by: smallPolygon))
    }

    func testPKStrokeLocationsPreservedAfterConversion() {
        let inputLocation = CGPoint(x: 500, y: 700)
        let pkPoint = PKStrokePoint(location: inputLocation, timeOffset: 0,
                                     size: CGSize(width: 5, height: 5), opacity: 1,
                                     force: 1, azimuth: 0, altitude: .pi / 4)
        let path = PKStrokePath(controlPoints: [pkPoint], creationDate: Date())
        let pkStroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        let stroke = StrokeConverter.convert(pkStroke)

        XCTAssertEqual(stroke.points[0].location.x, 500, accuracy: 1)
        XCTAssertEqual(stroke.points[0].location.y, 700, accuracy: 1)
    }

    func testLassoSelectsStrokeAtSameCoordinates() {
        let points = [
            StrokePoint(location: CGPoint(x: 500, y: 700), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: CGPoint(x: 510, y: 710), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ]
        let stroke = Stroke(points: points)

        let polygon = [
            CGPoint(x: 450, y: 650),
            CGPoint(x: 550, y: 650),
            CGPoint(x: 550, y: 750),
            CGPoint(x: 450, y: 750),
            CGPoint(x: 450, y: 650)
        ]
        XCTAssertTrue(LassoSelection.isStrokeSelected(stroke, by: polygon))
    }

    // MARK: - Coordinate system tests

    /// Verifies that sibling UIViews with the same frame have matching coordinate systems.
    func testSiblingViewsAtSameFrameHaveMatchingCoords() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let vc = UIViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()

        let viewA = UIView(frame: vc.view.bounds)
        let viewB = UIView(frame: vc.view.bounds)
        vc.view.addSubview(viewA)
        vc.view.addSubview(viewB)

        let testPoint = CGPoint(x: 500, y: 500)
        let converted = viewA.convert(testPoint, to: viewB)
        XCTAssertEqual(converted.x, testPoint.x, accuracy: 0.5)
        XCTAssertEqual(converted.y, testPoint.y, accuracy: 0.5)

        window.resignKey()
    }

    /// Verifies that convert(_:to:) corrects for different frame origins.
    func testConvertCorrectsBetweenOffsetViews() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let vc = UIViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()

        let topView = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let offsetView = UIView(frame: CGRect(x: 0, y: 86, width: 1024, height: 1280))
        vc.view.addSubview(topView)
        vc.view.addSubview(offsetView)

        // Point at (500, 414) in offsetView = screen position (500, 500)
        // Converted to topView = (500, 500)
        let point = CGPoint(x: 500, y: 414)
        let converted = offsetView.convert(point, to: topView)
        XCTAssertEqual(converted.x, 500, accuracy: 0.5)
        XCTAssertEqual(converted.y, 500, accuracy: 0.5,
                       "convert should add the 86pt offset: \(point.y) + 86 = \(converted.y)")

        window.resignKey()
    }

    /// Tests PKCanvasView content inset behavior.
    func testPKCanvasViewContentInsets() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let vc = UIViewController()
        let nav = UINavigationController(rootViewController: vc)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.view.layoutIfNeeded()

        let safeAreaTop = vc.view.safeAreaInsets.top

        let canvasView = PKCanvasView(frame: vc.view.bounds)
        vc.view.addSubview(canvasView)
        vc.view.layoutIfNeeded()

        // Check default content inset adjustment
        let defaultInset = canvasView.adjustedContentInset.top
        print("📐 PKCanvasView default adjustedContentInset.top: \(defaultInset)")
        print("📐 PKCanvasView contentInsetAdjustmentBehavior: \(canvasView.contentInsetAdjustmentBehavior.rawValue)")
        print("📐 safeAreaTop: \(safeAreaTop)")

        // Now set .never
        canvasView.contentInsetAdjustmentBehavior = .never
        vc.view.layoutIfNeeded()
        let neverInset = canvasView.adjustedContentInset.top
        print("📐 After .never, adjustedContentInset.top: \(neverInset)")

        // With .never, content inset should be 0
        XCTAssertEqual(neverInset, 0, accuracy: 0.5,
                       "With .never, adjustedContentInset.top should be 0")

        // Test: does a stroke placed programmatically at (500, 500) keep those coords?
        let pkPoint = PKStrokePoint(location: CGPoint(x: 500, y: 500), timeOffset: 0,
                                     size: CGSize(width: 5, height: 5), opacity: 1,
                                     force: 1, azimuth: 0, altitude: .pi / 4)
        let pkStroke = PKStroke(ink: PKInk(.pen, color: .black),
                                path: PKStrokePath(controlPoints: [pkPoint], creationDate: Date()))
        canvasView.drawing = PKDrawing(strokes: [pkStroke])

        let readBack = canvasView.drawing.strokes[0].path[0].location
        print("📐 Stroke input: (500, 500), readback: \(readBack)")
        XCTAssertEqual(readBack.x, 500, accuracy: 1)
        XCTAssertEqual(readBack.y, 500, accuracy: 1,
                       "PKStroke location should match input. Got y=\(readBack.y)")

        // Now check what contentOffset is
        print("📐 contentOffset: \(canvasView.contentOffset)")

        // Convert stroke location to window coords
        let strokeInWindow = canvasView.convert(readBack, to: window)
        print("📐 Stroke (500,500) in window coords: \(strokeInWindow)")

        window.resignKey()
    }

    /// Full integration test: PKCanvasView + SelectionView with nav bar, testing convert-based hit testing.
    func testViewBridgeCoordinateConversion() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let vc = UIViewController()
        let nav = UINavigationController(rootViewController: vc)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.view.layoutIfNeeded()

        let safeAreaTop = vc.view.safeAreaInsets.top
        XCTAssertGreaterThan(safeAreaTop, 0, "Need safe area for this test to be meaningful")

        // Canvas fills the whole view (origin at view's origin)
        let canvasView = PKCanvasView()
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.frame = vc.view.bounds
        vc.view.addSubview(canvasView)

        // Lasso view offset by safe area (simulating SwiftUI's layout)
        let lassoView = SelectionView()
        lassoView.frame = CGRect(x: 0, y: safeAreaTop,
                                  width: vc.view.bounds.width,
                                  height: vc.view.bounds.height - safeAreaTop)
        vc.view.addSubview(lassoView)
        vc.view.layoutIfNeeded()

        print("📐 Canvas frame: \(canvasView.frame)")
        print("📐 Lasso frame: \(lassoView.frame)")
        print("📐 Safe area top: \(safeAreaTop)")

        // Create a stroke at (500, 500) in canvas coords
        let pkPoint = PKStrokePoint(location: CGPoint(x: 500, y: 500), timeOffset: 0,
                                     size: CGSize(width: 5, height: 5), opacity: 1,
                                     force: 1, azimuth: 0, altitude: .pi / 4)
        let pkStroke = PKStroke(ink: PKInk(.pen, color: .black),
                                path: PKStrokePath(controlPoints: [pkPoint], creationDate: Date()))
        let stroke = StrokeConverter.convert(pkStroke)

        // Stroke is at screen position (500, 500).
        // In lasso view coords (origin at safeAreaTop): same screen position = (500, 500 - safeAreaTop)
        let lassoY = 500.0 - safeAreaTop
        let lassoPolygon = [
            CGPoint(x: 450, y: lassoY - 50), CGPoint(x: 550, y: lassoY - 50),
            CGPoint(x: 550, y: lassoY + 50), CGPoint(x: 450, y: lassoY + 50),
            CGPoint(x: 450, y: lassoY - 50)
        ]

        // Without conversion: should FAIL
        let withoutConversion = LassoSelection.isStrokeSelected(stroke, by: lassoPolygon)
        XCTAssertFalse(withoutConversion,
                        "Without conversion should fail (offset: \(safeAreaTop))")

        // Simulate the app's approach: lasso converts points to window coords,
        // then DrawingScreen converts window coords to canvas coords.
        let windowPolygon = lassoPolygon.map { lassoView.convert($0, to: nil) }
        print("📐 Lasso center in view coords: (500, \(lassoY))")
        print("📐 Lasso center in window coords: \(lassoView.convert(CGPoint(x: 500, y: lassoY), to: nil))")

        // Convert window coords → canvas coords (what the app does via ViewBridge)
        let canvasPolygon = windowPolygon.map { canvasView.convert($0, from: nil) }
        print("📐 Lasso center in canvas coords: \(canvasView.convert(lassoView.convert(CGPoint(x: 500, y: lassoY), to: nil), from: nil))")
        print("📐 Stroke location: \(stroke.points[0].location)")

        let withConversion = LassoSelection.isStrokeSelected(stroke, by: canvasPolygon)
        XCTAssertTrue(withConversion,
                       "After window→canvas conversion, stroke should be selected")

        // Also test ViewBridge pattern (only needs canvasView)
        let bridge = ViewBridge()
        bridge.canvasView = canvasView
        XCTAssertNotNil(bridge.canvasView, "ViewBridge should hold canvas reference")

        let bridgeConverted = windowPolygon.map { bridge.canvasView!.convert($0, from: nil) }
        let viaBridge = LassoSelection.isStrokeSelected(stroke, by: bridgeConverted)
        XCTAssertTrue(viaBridge, "ViewBridge-based window→canvas conversion should work")

        window.resignKey()
    }

    /// Tests that when both views have the SAME frame, no conversion offset is needed.
    func testNoOffsetWhenViewsShareFrame() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let vc = UIViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()

        let canvasView = PKCanvasView(frame: vc.view.bounds)
        canvasView.contentInsetAdjustmentBehavior = .never
        let lassoView = SelectionView()
        lassoView.frame = vc.view.bounds
        vc.view.addSubview(canvasView)
        vc.view.addSubview(lassoView)

        let testPoint = CGPoint(x: 500, y: 500)
        let converted = lassoView.convert(testPoint, to: canvasView)
        XCTAssertEqual(converted.x, 500, accuracy: 0.5)
        XCTAssertEqual(converted.y, 500, accuracy: 0.5,
                       "Same frame should mean no offset. Got \(converted)")

        window.resignKey()
    }

    /// Tests fallback when ViewBridge canvasView is nil.
    func testFallbackWhenBridgeRefNil() {
        let bridge = ViewBridge()
        XCTAssertNil(bridge.canvasView, "Fresh ViewBridge should have nil canvasView")
    }
}
