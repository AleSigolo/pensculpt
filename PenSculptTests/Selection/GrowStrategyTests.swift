import XCTest
@testable import PenSculpt

final class GrowStrategyTests: XCTestCase {

    private func stroke(at points: [CGPoint], id: UUID = UUID()) -> Stroke {
        let sps = points.map {
            StrokePoint(location: $0, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        }
        return Stroke(id: id, points: sps)
    }

    private func canvas(_ strokes: [Stroke]) -> Canvas {
        var c = Canvas()
        c.strokes = strokes
        return c
    }

    // MARK: start

    func testStrokeOriginIncludesItselfAtT0() {
        let id = UUID()
        let seed = stroke(at: [CGPoint(x: 100, y: 100)], id: id)
        let other = stroke(at: [CGPoint(x: 500, y: 500)])
        let session = GrowStrategy.start(
            origin: .stroke(strokeID: id, anchor: CGPoint(x: 100, y: 100)),
            mode: .add,
            candidatePool: canvas([seed, other]).strokes
        )
        XCTAssertTrue(session.includedStrokeIDs.contains(id))
        XCTAssertFalse(session.includedStrokeIDs.contains(other.id))
    }

    func testPointOriginIncludesNothingAtT0WhenNoStrokeWithinInitialRadius() {
        let far = stroke(at: [CGPoint(x: 500, y: 500)])
        let session = GrowStrategy.start(
            origin: .point(.zero),
            mode: .add,
            candidatePool: canvas([far]).strokes
        )
        XCTAssertTrue(session.includedStrokeIDs.isEmpty)
    }

    func testPointOriginIncludesStrokeWithinInitialRadius() {
        // initialRadius = 8 → strokes within 8 of origin enter immediately.
        let close = stroke(at: [CGPoint(x: 5, y: 0)])
        let session = GrowStrategy.start(
            origin: .point(.zero),
            mode: .add,
            candidatePool: canvas([close]).strokes
        )
        XCTAssertTrue(session.includedStrokeIDs.contains(close.id))
    }

    // MARK: tick — monotonic radius

    func testRadiusGrowsMonotonically() {
        let s = stroke(at: [CGPoint(x: 1000, y: 1000)])
        let session = GrowStrategy.start(origin: .point(.zero), mode: .add, candidatePool: canvas([s]).strokes)
        var lastR = session.currentRadius
        for _ in 0..<10 {
            let frame = session.tick(deltaTime: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(frame.radius, lastR)
            lastR = frame.radius
        }
    }

    // MARK: tick — admits strokes within radius

    func testTickIncludesCloseStrokeAfterEnoughTime() {
        // Stroke at distance 40; baseGrowthSpeed=50 px/s → reaches in ~0.64s.
        let target = stroke(at: [CGPoint(x: 40, y: 0)])
        let session = GrowStrategy.start(origin: .point(.zero), mode: .add, candidatePool: canvas([target]).strokes)
        let totalTime: TimeInterval = 1.0  // give it enough margin
        var t: TimeInterval = 0
        let dt = 1.0 / 60.0
        while t < totalTime {
            _ = session.tick(deltaTime: dt)
            t += dt
        }
        XCTAssertTrue(session.includedStrokeIDs.contains(target.id))
    }

    // MARK: pause behavior

    func testPauseTriggersWhenNextStrokeIsFar() {
        // Tight cluster near origin (immediate inclusion), then a big gap, then an isolated stroke.
        let cluster = (0..<3).map { i in
            stroke(at: [CGPoint(x: CGFloat(i) * 5, y: 0)])
        }
        let isolated = stroke(at: [CGPoint(x: 500, y: 0)])
        let session = GrowStrategy.start(
            origin: .point(.zero),
            mode: .add,
            candidatePool: canvas(cluster + [isolated]).strokes
        )
        // After cluster inclusion, density factor should drop below 1.0 within a few ticks.
        let dt: TimeInterval = 1.0 / 60.0
        let nominalDeltaR = GrowStrategy.baseGrowthSpeed * CGFloat(dt)
        var pausedFrame: (radius: CGFloat, prevRadius: CGFloat)?
        var prev = session.currentRadius
        for _ in 0..<10 {
            let frame = session.tick(deltaTime: dt)
            if frame.isPaused {
                pausedFrame = (frame.radius, prev)
                break
            }
            prev = frame.radius
        }
        guard let captured = pausedFrame else {
            return XCTFail("Expected pause when the only remaining candidate is far away")
        }
        // Verify the radius actually grew by less than full speed during the paused tick —
        // not just that the boolean flipped. With densityPauseFactor=0.1 we expect ~10%
        // of nominal step; allow some slack but require well below the full step.
        let observedDeltaR = captured.radius - captured.prevRadius
        XCTAssertLessThan(observedDeltaR, nominalDeltaR * 0.5,
                          "Paused tick should grow noticeably less than nominal (\(nominalDeltaR)); got \(observedDeltaR)")
    }

    // MARK: symmetry

    func testEquidistantStrokesAdmittedOnSameTick() {
        // Three parallel vertical lines: left at x=-100, middle at x=0,
        // right at x=+100, each from y=0 to y=100. Anchor exactly on the
        // middle line's midpoint, so:
        //   - middle is admitted at t=0 (initialRadius=8 covers (0,50))
        //   - left and right are perfectly symmetric w.r.t. the frontier
        //     (anchor + middle), so they must reach the radius together.
        let ys = stride(from: 0.0, through: 100.0, by: 10.0).map { CGFloat($0) }
        let left = stroke(at: ys.map { CGPoint(x: -100, y: $0) })
        let middle = stroke(at: ys.map { CGPoint(x: 0, y: $0) })
        let right = stroke(at: ys.map { CGPoint(x: 100, y: $0) })
        let session = GrowStrategy.start(
            origin: .point(CGPoint(x: 0, y: 50)),
            mode: .add,
            candidatePool: canvas([left, middle, right]).strokes
        )
        XCTAssertTrue(session.includedStrokeIDs.contains(middle.id),
                      "Middle line under the anchor should be admitted at t=0")
        XCTAssertFalse(session.includedStrokeIDs.contains(left.id))
        XCTAssertFalse(session.includedStrokeIDs.contains(right.id))

        let dt: TimeInterval = 1.0 / 60.0
        var leftTick: Int?
        var rightTick: Int?
        for i in 1...600 {
            _ = session.tick(deltaTime: dt)
            if leftTick == nil, session.includedStrokeIDs.contains(left.id) {
                leftTick = i
            }
            if rightTick == nil, session.includedStrokeIDs.contains(right.id) {
                rightTick = i
            }
            if leftTick != nil && rightTick != nil { break }
        }
        XCTAssertNotNil(leftTick, "Left line should be admitted within 600 ticks")
        XCTAssertNotNil(rightTick, "Right line should be admitted within 600 ticks")
        XCTAssertEqual(leftTick, rightTick,
                       "Equidistant strokes must be admitted on the same tick (left=\(String(describing: leftTick)), right=\(String(describing: rightTick)))")
    }

    func testAsymmetricAnchorAdmitsSidesCloseTogether() {
        // Same three-line layout, but anchor shifted 5pt to the right of the
        // middle line. Without co-admit, the density pause amplifies that 5pt
        // anchor offset into ~20 ticks of lag between right and left admissions.
        // With co-admit, the gap should collapse to a single tick.
        let ys = stride(from: 0.0, through: 100.0, by: 10.0).map { CGFloat($0) }
        let left = stroke(at: ys.map { CGPoint(x: -100, y: $0) })
        let middle = stroke(at: ys.map { CGPoint(x: 0, y: $0) })
        let right = stroke(at: ys.map { CGPoint(x: 100, y: $0) })
        let session = GrowStrategy.start(
            origin: .point(CGPoint(x: 5, y: 50)),
            mode: .add,
            candidatePool: canvas([left, middle, right]).strokes
        )
        // Middle line still under the anchor → admitted at t=0.
        XCTAssertTrue(session.includedStrokeIDs.contains(middle.id))

        let dt: TimeInterval = 1.0 / 60.0
        var leftTick: Int?
        var rightTick: Int?
        for i in 1...600 {
            _ = session.tick(deltaTime: dt)
            if leftTick == nil, session.includedStrokeIDs.contains(left.id) {
                leftTick = i
            }
            if rightTick == nil, session.includedStrokeIDs.contains(right.id) {
                rightTick = i
            }
            if leftTick != nil && rightTick != nil { break }
        }
        guard let l = leftTick, let r = rightTick else {
            return XCTFail("Both sides should be admitted within 600 ticks (left=\(String(describing: leftTick)), right=\(String(describing: rightTick)))")
        }
        // Right is closer, so it admits first or on the same tick. Co-admit
        // should bring the left side in immediately after — within 2 ticks.
        XCTAssertLessThanOrEqual(abs(r - l), 2,
                                 "Co-admit should keep left/right within 2 ticks despite 5pt anchor offset (left=\(l), right=\(r))")
    }

    // MARK: finalize

    func testFinalizeReturnsCurrentlyIncludedSet() {
        let id = UUID()
        let seed = stroke(at: [CGPoint(x: 0, y: 0)], id: id)
        let session = GrowStrategy.start(
            origin: .stroke(strokeID: id, anchor: .zero),
            mode: .add,
            candidatePool: canvas([seed]).strokes
        )
        XCTAssertEqual(session.finalize(), [id])
    }

    func testFinalizeMatchesIncludedAfterTicks() {
        // Origin point at zero with one stroke at distance 30 — reachable in <1s
        // at baseGrowthSpeed=50.
        let target = stroke(at: [CGPoint(x: 30, y: 0)])
        let session = GrowStrategy.start(origin: .point(.zero), mode: .add, candidatePool: canvas([target]).strokes)
        for _ in 0..<60 {
            _ = session.tick(deltaTime: 1.0 / 60.0)
        }
        let finalized = session.finalize()
        XCTAssertEqual(finalized, session.includedStrokeIDs,
                       "finalize() must be a snapshot of includedStrokeIDs after ticks")
        XCTAssertTrue(finalized.contains(target.id))
        // Calling finalize again must not mutate the session.
        let secondCall = session.finalize()
        XCTAssertEqual(finalized, secondCall)
    }
}
