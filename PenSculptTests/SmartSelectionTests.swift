import XCTest
@testable import PenSculpt

final class SmartSelectionTests: XCTestCase {

    private func stroke(_ a: CGPoint, _ b: CGPoint) -> Stroke {
        Stroke(points: [
            StrokePoint(location: a, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: b, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
    }

    /// near (closest point ~10pt from origin) and far (~100pt from origin).
    /// Groups are built directly to keep these tests isolated from StrokeClustering.
    private func fixture() -> (strokes: [Stroke], groups: [StrokeGroup], near: Stroke, far: Stroke) {
        let near = stroke(CGPoint(x: 10, y: 0), CGPoint(x: 50, y: 0))
        let far = stroke(CGPoint(x: 100, y: 0), CGPoint(x: 150, y: 0))
        let groups = [
            StrokeGroup(strokeIDs: [near.id], boundingBox: near.boundingBox),
            StrokeGroup(strokeIDs: [far.id], boundingBox: far.boundingBox)
        ]
        return ([near, far], groups, near, far)
    }

    func testGroupDistancesUseNearestPoint() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        // Two separate groups (gap 50 > 24).
        XCTAssertEqual(distances.count, 2)
        let nearEntry = distances.first { $0.group.strokeIDs.contains(f.near.id) }
        XCTAssertEqual(nearEntry?.distance ?? -1, 10, accuracy: 0.5)
    }

    func testNearestDistanceIsTheSeed() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        XCTAssertEqual(SmartSelection.nearestDistance(distances), 10, accuracy: 0.5)
    }

    func testReachAtSeedSelectsOnlyNearest() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        let ids = SmartSelection.groupsWithin(reach: 10, distances: distances)
        XCTAssertTrue(ids.contains(f.near.id))
        XCTAssertFalse(ids.contains(f.far.id))
    }

    func testLargerReachPullsInFartherGroup() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        let ids = SmartSelection.groupsWithin(reach: 100, distances: distances)
        XCTAssertTrue(ids.contains(f.near.id))
        XCTAssertTrue(ids.contains(f.far.id))
    }

    func testReachIsMonotonic() {
        let f = fixture()
        let distances = SmartSelection.groupDistances(
            groups: f.groups, strokes: f.strokes, from: .zero)
        let small = SmartSelection.groupsWithin(reach: 10, distances: distances)
        let large = SmartSelection.groupsWithin(reach: 100, distances: distances)
        XCTAssertTrue(small.isSubset(of: large))
    }

    func testNoGroupsGivesZeroSeedAndEmptySelection() {
        XCTAssertEqual(SmartSelection.nearestDistance([]), 0, accuracy: 0.0001)
        XCTAssertTrue(SmartSelection.groupsWithin(reach: 999, distances: []).isEmpty)
    }

    func testGroupWithUnknownStrokeIDGetsMaxDistance() {
        let phantomGroup = StrokeGroup(strokeIDs: [UUID()], boundingBox: .zero)
        let distances = SmartSelection.groupDistances(groups: [phantomGroup], strokes: [], from: .zero)
        XCTAssertEqual(distances[0].distance, .greatestFiniteMagnitude)
    }
}
