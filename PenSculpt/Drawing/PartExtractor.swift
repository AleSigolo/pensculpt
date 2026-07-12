import Foundation

/// A closed region extracted from a single stroke — one inflation part.
/// The contour is an implicitly closed polygon (last→first edge implied),
/// matching ShapeInflater.containsAndDistance's wrap-around convention.
struct Part: Codable, Equatable, Sendable {
    var contour: [CGPoint]
    let sourceStrokeID: UUID
}

enum PartExtractor {

    /// Extracts closed-loop parts from an object's strokes. Open strokes
    /// never become parts — they stay as surface decoration ink.
    static func parts(from strokes: [Stroke], config: SculptConfig = .default) -> [Part] {
        strokes.compactMap { part(from: $0, config: config) }
    }

    private static func part(from stroke: Stroke, config: SculptConfig) -> Part? {
        let points = stroke.points.map(\.location)
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }

        var arcLength: CGFloat = 0
        for i in 1..<points.count {
            arcLength += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        guard arcLength > 0 else { return nil }

        let gap = hypot(last.x - first.x, last.y - first.y)
        guard gap <= config.partClosureRatio * arcLength else { return nil }

        guard abs(signedArea(points)) >= config.partMinArea else { return nil }

        return Part(contour: points, sourceStrokeID: stroke.id)
    }

    /// Shoelace formula over the implicitly closed loop.
    static func signedArea(_ loop: [CGPoint]) -> CGFloat {
        guard loop.count >= 3 else { return 0 }
        var area: CGFloat = 0
        var j = loop.count - 1
        for i in 0..<loop.count {
            area += loop[j].x * loop[i].y - loop[i].x * loop[j].y
            j = i
        }
        return area / 2
    }
}
