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

        var contour = smoothed(points, passes: config.partSmoothingPasses)
        if contour.count > Int(config.contourMaxPoints) {
            contour = ContourExtractor.simplify(contour, tolerance: 1.0)
        }
        guard contour.count >= 3,
              abs(signedArea(contour)) >= config.partMinArea else { return nil }

        return Part(contour: contour, sourceStrokeID: stroke.id)
    }

    /// Wrap-around 1-2-1 Laplacian smoothing over the closed loop. Kills ink
    /// wobble; the center weight limits the shrink of plain neighbor averaging.
    static func smoothed(_ loop: [CGPoint], passes: Int) -> [CGPoint] {
        guard passes > 0, loop.count >= 3 else { return loop }
        var pts = loop
        for _ in 0..<passes {
            let n = pts.count
            var next = pts
            for i in 0..<n {
                let prev = pts[(i + n - 1) % n]
                let succ = pts[(i + 1) % n]
                next[i] = CGPoint(x: (prev.x + 2 * pts[i].x + succ.x) / 4,
                                  y: (prev.y + 2 * pts[i].y + succ.y) / 4)
            }
            pts = next
        }
        return pts
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
