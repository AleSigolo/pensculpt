import Foundation

/// Reach-based selection: groups are ordered by distance from the hold point
/// and pulled in (whole) once the growing reach radius reaches them.
enum SmartSelection {

    /// Pairs each group with the distance from `holdPoint` to its nearest ink
    /// point. `holdPoint` and stroke locations must be in the same coordinate
    /// space (canvas coordinates).
    static func groupDistances(
        groups: [StrokeGroup],
        strokes: [Stroke],
        from holdPoint: CGPoint
    ) -> [(group: StrokeGroup, distance: CGFloat)] {
        let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.map { group in
            var best = CGFloat.greatestFiniteMagnitude
            for id in group.strokeIDs {
                guard let stroke = byID[id] else { continue }
                for p in stroke.points {
                    let dx = p.location.x - holdPoint.x
                    let dy = p.location.y - holdPoint.y
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < best { best = d }
                }
            }
            return (group, best)
        }
    }

    /// Distance to the nearest group — the seed reach. Zero when there are no groups.
    static func nearestDistance(
        _ distances: [(group: StrokeGroup, distance: CGFloat)]
    ) -> CGFloat {
        distances.map { $0.distance }.min() ?? 0
    }

    /// Stroke IDs of every group whose nearest point is within `reach`.
    static func groupsWithin(
        reach: CGFloat,
        distances: [(group: StrokeGroup, distance: CGFloat)]
    ) -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in distances where entry.distance <= reach {
            ids.formUnion(entry.group.strokeIDs)
        }
        return ids
    }
}
