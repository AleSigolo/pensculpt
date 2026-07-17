import Foundation

/// A closed region extracted from a single stroke — one inflation part.
/// The contour is an implicitly closed polygon (last→first edge implied),
/// matching ShapeInflater.containsAndDistance's wrap-around convention.
struct Part: Codable, Equatable, Sendable {
    var contour: [CGPoint]
    let sourceStrokeID: Stroke.ID
}

enum PartExtractor {

    /// Extracts inflatable parts from an object's strokes:
    /// 1. Closed-loop strokes (endpoint gap within the ratio OR the absolute
    ///    tolerance — hand-drawn shapes rarely close within 20% on small
    ///    figures).
    /// 2. Anchored appendages: open strokes whose BOTH endpoints rest on a
    ///    closed part's contour (the "Λ" horn leaning on a head — the
    ///    natural way the target audience draws appendages). They close with
    ///    their implicit end-to-end edge; the smooth-max depth blend unions
    ///    them into the host, so no topology surgery is needed.
    /// Everything else stays surface decoration ink.
    static func parts(from strokes: [Stroke], config: SculptConfig = .default) -> [Part] {
        var closed: [Part] = []
        var openStrokes: [Stroke] = []
        for stroke in strokes {
            if let p = part(from: stroke, config: config) {
                closed.append(p)
            } else {
                openStrokes.append(stroke)
            }
        }
        guard !closed.isEmpty else { return closed }
        let appendages = openStrokes.compactMap {
            anchoredPart(from: $0, hosts: closed, config: config)
        }
        return closed + appendages
    }

    /// An open stroke becomes a part when both endpoints anchor to closed-
    /// part ink; the loop is the stroke itself, implicitly closed end-to-end
    /// (the closing edge lies on/inside the host, and the depth-field union
    /// covers the seam).
    private static func anchoredPart(from stroke: Stroke, hosts: [Part],
                                     config: SculptConfig) -> Part? {
        let points = stroke.points.map(\.location)
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }
        guard isAnchored(first, to: hosts, tolerance: config.partAnchorTolerance),
              isAnchored(last, to: hosts, tolerance: config.partAnchorTolerance) else { return nil }

        var contour = smoothed(points, passes: config.partSmoothingPasses)
        if contour.count > Int(config.contourMaxPoints) {
            contour = ContourExtractor.simplify(contour, tolerance: 1.0)
        }
        guard contour.count >= 3,
              abs(signedArea(contour)) >= config.partMinArea else { return nil }
        return Part(contour: contour, sourceStrokeID: stroke.id)
    }

    private static func isAnchored(_ point: CGPoint, to hosts: [Part],
                                   tolerance: CGFloat) -> Bool {
        for host in hosts {
            let contour = host.contour
            guard contour.count >= 2 else { continue }
            var j = contour.count - 1
            for i in 0..<contour.count {
                if distanceToSegment(point, contour[j], contour[i]) <= tolerance {
                    return true
                }
                j = i
            }
        }
        return false
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSq = ab.x * ab.x + ab.y * ab.y
        guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSq))
        return hypot(p.x - (a.x + t * ab.x), p.y - (a.y + t * ab.y))
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
        let xs = points.map(\.x), ys = points.map(\.y)
        let bboxDiagonal = hypot((xs.max() ?? 0) - (xs.min() ?? 0),
                                 (ys.max() ?? 0) - (ys.min() ?? 0))
        guard gap <= max(config.partClosureRatio * arcLength,
                         config.partClosureAbsolute,
                         config.partClosureBBoxRatio * bboxDiagonal) else { return nil }

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
