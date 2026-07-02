import PencilKit
import UIKit

enum StrokeConverter {

    static func convert(_ pkStroke: PKStroke) -> Stroke {
        let path = pkStroke.path
        var points: [StrokePoint] = []
        points.reserveCapacity(path.count)

        for i in 0..<path.count {
            let p = path[i]
            points.append(StrokePoint(
                location: p.location,
                // Pressure canonically stores rendered-ink-width / widthPerPressure
                // so PK → internal → PK round-trips the width exactly. Raw force
                // is unreliable for finger input (always 0) and ignores the pen
                // width setting.
                pressure: p.size.width / CGFloat(StrokeLifter.widthPerPressure),
                tilt: p.altitude,
                azimuth: p.azimuth,
                timestamp: p.timeOffset
            ))
        }

        let color = colorFromPKInk(pkStroke.ink)
        return Stroke(points: points, color: color)
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
