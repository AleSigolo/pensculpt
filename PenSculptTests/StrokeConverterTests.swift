import XCTest
import PencilKit
@testable import PenSculpt

final class StrokeConverterTests: XCTestCase {

    func testConvertPKStroke() {
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

        XCTAssertEqual(stroke.points.count, 2)
        XCTAssertEqual(stroke.points[0].location, CGPoint(x: 0, y: 0))
        // Pressure is canonically rendered-ink-width / widthPerPressure, NOT
        // the raw force (which is unreliable for finger input and ignores the
        // pen width setting). size 5 → pressure 5/8.
        XCTAssertEqual(stroke.points[0].pressure, 0.625, accuracy: 1e-6)
        XCTAssertEqual(stroke.points[1].location, CGPoint(x: 100, y: 100))
        // Color should be extracted from ink, not hardcoded
        XCTAssertEqual(stroke.color.red, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.green, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.blue, 0, accuracy: 0.01)
        XCTAssertEqual(stroke.color.alpha, 1, accuracy: 0.01)
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

        XCTAssertEqual(roundTripped.path.count, 2)
        XCTAssertEqual(roundTripped.path[0].size.width, 3, accuracy: 0.01)
        XCTAssertEqual(roundTripped.path[1].size.width, 3, accuracy: 0.01)
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
