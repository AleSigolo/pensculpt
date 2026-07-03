import XCTest
import PencilKit
@testable import PenSculpt

final class StrokeConverterTests: XCTestCase {

    func testConvertPKStroke() throws {
        let points = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 0.5, azimuth: 0, altitude: .pi / 4),
            PKStrokePoint(location: CGPoint(x: 100, y: 100), timeOffset: 0.1,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 0.8, azimuth: 0.5, altitude: .pi / 3)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let ink = PKInk(.pen, color: .black)
        let pkStroke = PKStroke(ink: ink, path: path)

        let stroke = StrokeConverter.convert(pkStroke)

        // The rendered curve is sampled densely (see
        // testConvertSamplesTheRenderedCurveNotControlPoints); endpoints and
        // widths are what round-trip, not the control-point count.
        XCTAssertGreaterThan(stroke.points.count, 2)
        let first = try XCTUnwrap(stroke.points.first)
        let last = try XCTUnwrap(stroke.points.last)
        XCTAssertEqual(first.location.x, 0, accuracy: 0.01)
        XCTAssertEqual(first.location.y, 0, accuracy: 0.01)
        // Pressure is canonically rendered-ink-width / widthPerPressure, NOT
        // the raw force (which is unreliable for finger input and ignores the
        // pen width setting). size 5 → pressure 5/8.
        XCTAssertEqual(first.pressure, 0.625, accuracy: 1e-6)
        XCTAssertEqual(last.location.x, 100, accuracy: 0.01)
        XCTAssertEqual(last.location.y, 100, accuracy: 0.01)
        // Color should be extracted from ink, not hardcoded
        XCTAssertEqual(stroke.color.red, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.green, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.blue, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.alpha, 1, accuracy: 0.01)
    }

    func testConvertSamplesTheRenderedCurveNotControlPoints() {
        // A slow curved stroke has sparse spline control points; PencilKit
        // renders a smooth curve through them. The model polyline must
        // sample that curve densely — consuming raw control points leaves
        // 3D-lifted ink angular ("serpentine") and its width jittery.
        let controls = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 120),
                        CGPoint(x: 200, y: 0), CGPoint(x: 300, y: 120)]
        let points = controls.enumerated().map { i, loc in
            PKStrokePoint(location: loc, timeOffset: Double(i) * 0.2,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let pkStroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)

        let stroke = StrokeConverter.convert(pkStroke)

        XCTAssertGreaterThan(stroke.points.count, 50,
                             "4 sparse control points over ~450pt of curve must interpolate densely")
        // Consecutive samples must be close (no long straight chords).
        for i in 1..<stroke.points.count {
            let a = stroke.points[i - 1].location
            let b = stroke.points[i].location
            XCTAssertLessThan(hypot(b.x - a.x, b.y - a.y), 8,
                              "gap between samples \(i-1) and \(i) is a chord, not a curve")
        }
    }

    func testConvertPKDrawing() {
        let points = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 4)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let ink = PKInk(.pen, color: .black)
        let pkStroke = PKStroke(ink: ink, path: path)
        let drawing = PKDrawing(strokes: [pkStroke])

        let strokes = StrokeConverter.convertAll(drawing)

        XCTAssertEqual(strokes.count, 1)
    }

    func testWidthRoundTripsThroughInternalStroke() {
        // A finger stroke (force 0) drawn at the default 3pt pen width must
        // come back at exactly 3pt after PK → internal → PK.
        let points = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 0, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0.1,
                          size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 0, azimuth: 0, altitude: .pi / 2)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let pkStroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)

        let roundTripped = StrokeConverter.toPKStroke(StrokeConverter.convert(pkStroke))

        // Densified sampling changes the control-point count; the WIDTH is
        // what must survive the round trip, at every sample.
        XCTAssertGreaterThanOrEqual(roundTripped.path.count, 2)
        for i in 0..<roundTripped.path.count {
            XCTAssertEqual(roundTripped.path[i].size.width, 3, accuracy: 0.01)
        }
    }

    func testConvertPreservesInkColor() {
        let points = [
            PKStrokePoint(location: CGPoint(x: 0, y: 0), timeOffset: 0,
                          size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 4)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let ink = PKInk(.pen, color: .red)
        let pkStroke = PKStroke(ink: ink, path: path)

        let stroke = StrokeConverter.convert(pkStroke)

        XCTAssertEqual(stroke.color.red, 1, accuracy: 0.01)
        XCTAssertEqual(stroke.color.green, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.blue, 0, accuracy: 0.01)
    }
}
