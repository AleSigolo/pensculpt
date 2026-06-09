import Foundation

/// Groups strokes into "objects" by ink proximity. Two strokes belong to the
/// same group when the minimum distance between any of their sampled points is
/// within `linkDistance`. Grouping is transitive (connected components).
enum StrokeClustering {

    static func groups(from strokes: [Stroke], linkDistance: CGFloat) -> [StrokeGroup] {
        guard !strokes.isEmpty else { return [] }

        var parent = Array(0..<strokes.count)

        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var node = i
            while parent[node] != node {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Broadphase: inflate each box by linkDistance; if an inflated box does
        // not touch the other's box, the strokes cannot be within linkDistance.
        let inflated = strokes.map { $0.boundingBox.insetBy(dx: -linkDistance, dy: -linkDistance) }

        for i in 0..<strokes.count {
            for j in (i + 1)..<strokes.count {
                guard find(i) != find(j) else { continue }
                guard inflated[i].intersects(strokes[j].boundingBox) else { continue }
                if minDistance(strokes[i], strokes[j]) <= linkDistance {
                    union(i, j)
                }
            }
        }

        var byRoot: [Int: [Int]] = [:]
        for i in 0..<strokes.count {
            byRoot[find(i), default: []].append(i)
        }

        return byRoot.values.map { indices in
            let ids = Set(indices.map { strokes[$0].id })
            let box = indices.dropFirst().reduce(strokes[indices[0]].boundingBox) {
                $0.union(strokes[$1].boundingBox)
            }
            return StrokeGroup(strokeIDs: ids, boundingBox: box)
        }
    }

    /// Minimum Euclidean distance between any sampled point of `a` and `b`.
    /// O(points(a) * points(b)) — acceptable at current stroke counts.
    static func minDistance(_ a: Stroke, _ b: Stroke) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for pa in a.points {
            for pb in b.points {
                let dx = pa.location.x - pb.location.x
                let dy = pa.location.y - pb.location.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < best { best = d }
            }
        }
        return best
    }
}
