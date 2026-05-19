import Foundation

enum GrowMode {
    case add
    case subtract
}

/// One frame of grow-session state for visualization consumers.
struct GrowFrame {
    let radius: CGFloat
    let center: CGPoint
    let includedStrokeIDs: Set<UUID>
    let nextCandidateID: UUID?
    let isPaused: Bool
    let mode: GrowMode
}

enum GrowStrategy: SelectionStrategy {
    typealias Input = GrowOrigin

    // MARK: Tunables (iterate during manual testing)
    static let baseGrowthSpeed: CGFloat = 50.0
    static let densityPauseFactor: CGFloat = 0.3
    static let densityPauseThreshold: CGFloat = 3.0
    static let initialRadius: CGFloat = 8.0
    /// After a tick admits at least one stroke, also admit any candidate within
    /// `coAdmitCatchUpFactor × nominalDeltaR` beyond the current radius. Kills
    /// the asymmetric "lag" the density pause would otherwise introduce for
    /// strokes only a few frames away from the admitted one. At 15 frames
    /// (~250ms at 60fps) the catch-up window covers ~12pt of input
    /// microdifference without skipping over genuinely distant clusters.
    static let coAdmitCatchUpFactor: CGFloat = 15.0

    /// Starts a new grow session, immediately admitting any strokes within `initialRadius`
    /// (and the seed stroke itself, if origin is `.stroke`).
    static func start(origin: GrowOrigin, mode: GrowMode, candidatePool: [Stroke]) -> GrowSession {
        let session = GrowSession(origin: origin, mode: mode, candidatePool: candidatePool)
        session.admitInitial()
        return session
    }
}

/// Mutable per-hold state. Driven by `tick(deltaTime:)` from a display link.
final class GrowSession {
    let origin: GrowOrigin
    let mode: GrowMode
    let candidatePool: [Stroke]

    private(set) var currentRadius: CGFloat = GrowStrategy.initialRadius
    private(set) var includedStrokeIDs: Set<UUID> = []
    private(set) var nextCandidateID: UUID?
    private(set) var isPaused: Bool = false

    init(origin: GrowOrigin, mode: GrowMode, candidatePool: [Stroke]) {
        self.origin = origin
        self.mode = mode
        self.candidatePool = candidatePool
    }

    /// Admit seed (for stroke origins) and any strokes already within `initialRadius`.
    func admitInitial() {
        if let seedID = origin.initialStrokeID {
            includedStrokeIDs.insert(seedID)
        }
        admitWithinRadius(catchUpRadius: 0)
        recomputeNextCandidate()
    }

    /// Advances by `deltaTime` seconds. Updates radius (modulated by density), admits
    /// strokes inside the new radius, recomputes the next candidate and pause state.
    @discardableResult
    func tick(deltaTime: TimeInterval) -> GrowFrame {
        // No candidates means either an empty canvas or every stroke admitted —
        // freeze the radius (and CPU) instead of growing the sphere indefinitely.
        guard !candidateStrokes.isEmpty else {
            isPaused = false
            return GrowFrame(
                radius: currentRadius,
                center: origin.anchor,
                includedStrokeIDs: includedStrokeIDs,
                nextCandidateID: nil,
                isPaused: false,
                mode: mode
            )
        }
        let nominalDeltaR = GrowStrategy.baseGrowthSpeed * CGFloat(deltaTime)
        let densityFactor = computeDensityFactor(nominalDeltaR: nominalDeltaR)
        let appliedDeltaR = nominalDeltaR * densityFactor
        currentRadius += appliedDeltaR
        admitWithinRadius(catchUpRadius: nominalDeltaR * GrowStrategy.coAdmitCatchUpFactor)
        recomputeNextCandidate()
        // Anything below full speed is "paused" for the user — the visualization
        // halo signals the slowdown, not a specific factor.
        isPaused = densityFactor < 1.0

        return GrowFrame(
            radius: currentRadius,
            center: origin.anchor,
            includedStrokeIDs: includedStrokeIDs,
            nextCandidateID: nextCandidateID,
            isPaused: isPaused,
            mode: mode
        )
    }

    /// Returns the final selection (snapshot of included strokes). Idempotent.
    func finalize() -> Set<UUID> {
        return includedStrokeIDs
    }

    // MARK: - Internals

    private var frontierPoints: [CGPoint] {
        var pts: [CGPoint] = [origin.anchor]
        for s in candidatePool where includedStrokeIDs.contains(s.id) {
            pts.append(contentsOf: s.points.map { $0.location })
        }
        return pts
    }

    private var candidateStrokes: [Stroke] {
        candidatePool.filter { !includedStrokeIDs.contains($0.id) }
    }

    private func admitWithinRadius(catchUpRadius: CGFloat) {
        let beforeCount = includedStrokeIDs.count
        let frontier = frontierPoints
        for stroke in candidateStrokes {
            var bestMinD = CGFloat.infinity
            for sp in stroke.points {
                var minD = CGFloat.infinity
                for fp in frontier {
                    let d = hypot(sp.location.x - fp.x, sp.location.y - fp.y)
                    if d < minD { minD = d }
                }
                if minD < bestMinD { bestMinD = minD }
                if minD <= currentRadius {
                    includedStrokeIDs.insert(stroke.id)
                    break
                }
            }
            // DIAG: log strokes that are NOT admitted with their distance vs radius.
            if !includedStrokeIDs.contains(stroke.id) {
                let firstPt = stroke.points.first?.location ?? .zero
                print("[GROW-DIAG] stroke=\(stroke.id.uuidString.prefix(8)) firstPt=(\(Int(firstPt.x)),\(Int(firstPt.y))) bbox=\(stroke.boundingBox) minD=\(Int(bestMinD)) radius=\(Int(currentRadius)) anchor=(\(Int(origin.anchor.x)),\(Int(origin.anchor.y))) points=\(stroke.points.count)")
            }
        }

        // Co-admit pass: when the main pass admitted at least one stroke, sweep
        // candidates again against the *updated* frontier with an extended radius.
        // Pulls in anything close enough that the density pause would otherwise
        // amplify a microdifference into perceptible lag (the right/left
        // asymmetry the user reported).
        guard catchUpRadius > 0, includedStrokeIDs.count > beforeCount else { return }
        let extendedRadius = currentRadius + catchUpRadius
        let updatedFrontier = frontierPoints
        for stroke in candidateStrokes {
            for sp in stroke.points {
                var minD = CGFloat.infinity
                for fp in updatedFrontier {
                    let d = hypot(sp.location.x - fp.x, sp.location.y - fp.y)
                    if d < minD { minD = d }
                }
                if minD <= extendedRadius {
                    includedStrokeIDs.insert(stroke.id)
                    break
                }
            }
        }
    }

    private func recomputeNextCandidate() {
        let frontier = frontierPoints
        var bestID: UUID?
        var bestD = CGFloat.infinity
        for stroke in candidateStrokes {
            for sp in stroke.points {
                for fp in frontier {
                    let d = hypot(sp.location.x - fp.x, sp.location.y - fp.y)
                    if d < bestD { bestD = d; bestID = stroke.id }
                }
            }
        }
        nextCandidateID = bestID
    }

    /// 1.0 = full speed; less = slowdown. Pause when next-stroke gap is much
    /// larger than what we'd cross in this tick at full speed. Doesn't pause
    /// before any strokes are admitted — the user is still waiting for the
    /// first inclusion, so the radius needs to grow at full speed to find it.
    private func computeDensityFactor(nominalDeltaR: CGFloat) -> CGFloat {
        guard !includedStrokeIDs.isEmpty else { return 1.0 }
        guard let deltaR = DensityProbe.minimumDeltaR(
            currentRadius: currentRadius,
            frontier: frontierPoints,
            candidates: candidateStrokes
        ), nominalDeltaR > 0 else {
            return 1.0
        }
        let ratio = deltaR / nominalDeltaR
        if ratio > GrowStrategy.densityPauseThreshold {
            return GrowStrategy.densityPauseFactor
        }
        return 1.0
    }
}
