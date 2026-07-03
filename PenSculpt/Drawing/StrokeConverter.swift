import PencilKit
import UIKit

enum StrokeConverter {

    /// Sample spacing (points) when converting a PK spline to the model
    /// polyline. Matches the inflation grid (SculptConfig.gridSpacing).
    static let interpolationSpacing: CGFloat = 2

    static func convert(_ pkStroke: PKStroke) -> Stroke {
        let path = pkStroke.path
        var points: [StrokePoint] = []

        // PencilKit renders a smooth spline through its control points, whose
        // spacing depends on drawing speed — a slow curve can span 100+pt
        // between controls. Everything downstream (3D lift, contour
        // inference, selection distances, the Metal stroke strip) consumes
        // the model as a POLYLINE, so sample the rendered curve; raw control
        // points leave lifted ink angular and its width jittery.
        if path.count >= 2 {
            for p in path.interpolatedPoints(by: .distance(Self.interpolationSpacing)) {
                points.append(strokePoint(from: p))
            }
        } else {
            for i in 0..<path.count {
                points.append(strokePoint(from: path[i]))
            }
        }

        let color = colorFromPKInk(pkStroke.ink)
        return Stroke(points: points, color: color)
    }

    private static func strokePoint(from p: PKStrokePoint) -> StrokePoint {
        StrokePoint(
            location: p.location,
            // Pressure canonically stores rendered-ink-width / widthPerPressure
            // so PK → internal → PK round-trips the width exactly. Raw force
            // is unreliable for finger input (always 0) and ignores the pen
            // width setting.
            pressure: p.size.width / CGFloat(StrokeLifter.widthPerPressure),
            tilt: p.altitude,
            azimuth: p.azimuth,
            timestamp: p.timeOffset
        )
    }

    static func convertAll(_ drawing: PKDrawing) -> [Stroke] {
        drawing.strokes.map { convert($0) }
    }

    static func toPKStroke(_ stroke: Stroke) -> PKStroke {
        let controlPoints = stroke.points.map { p in
            PKStrokePoint(
                location: p.location,
                timeOffset: p.timestamp,
                size: CGSize(width: p.pressure * CGFloat(StrokeLifter.widthPerPressure),
                             height: p.pressure * CGFloat(StrokeLifter.widthPerPressure)),
                opacity: stroke.color.alpha,
                force: p.pressure,
                azimuth: p.azimuth,
                altitude: p.tilt
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        let color = UIColor(red: stroke.color.red, green: stroke.color.green,
                            blue: stroke.color.blue, alpha: stroke.color.alpha)
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }

    private static func colorFromPKInk(_ ink: PKInk) -> CodableColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CodableColor(red: r, green: g, blue: b, alpha: a)
    }
}
