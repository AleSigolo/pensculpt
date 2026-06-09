import XCTest
@testable import PenSculpt

final class StrokeClusteringTests: XCTestCase {

    private func stroke(_ a: CGPoint, _ b: CGPoint) -> Stroke {
        Stroke(points: [
            StrokePoint(location: a, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokePoint(location: b, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0.1)
        ])
    }

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(StrokeClustering.groups(from: [], linkDistance: 24).isEmpty)
    }

    func testSingleStrokeIsOneGroup() {
        let s = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        let groups = StrokeClustering.groups(from: [s], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokeIDs, [s.id])
    }

    func testNearStrokesMergeIntoOneGroup() {
        // Endpoints 10pt apart, link distance 24 → same object.
        let s1 = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let s2 = stroke(CGPoint(x: 110, y: 0), CGPoint(x: 200, y: 0))
        let groups = StrokeClustering.groups(from: [s1, s2], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokeIDs, [s1.id, s2.id])
    }

    func testFarStrokesStaySeparate() {
        // Endpoints 200pt apart, link distance 24 → two objects.
        let s1 = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let s2 = stroke(CGPoint(x: 300, y: 0), CGPoint(x: 400, y: 0))
        let groups = StrokeClustering.groups(from: [s1, s2], linkDistance: 24)
        XCTAssertEqual(groups.count, 2)
    }

    func testTransitiveChainMergesAll() {
        // A near B, B near C, A far from C → all one group via the chain.
        let a = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0))
        let b = stroke(CGPoint(x: 60, y: 0), CGPoint(x: 110, y: 0))
        let c = stroke(CGPoint(x: 120, y: 0), CGPoint(x: 170, y: 0))
        let groups = StrokeClustering.groups(from: [a, b, c], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokeIDs, [a.id, b.id, c.id])
    }

    func testGroupBoundingBoxIsUnionOfMembers() {
        let s1 = stroke(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        let s2 = stroke(CGPoint(x: 110, y: 0), CGPoint(x: 200, y: 50))
        let groups = StrokeClustering.groups(from: [s1, s2], linkDistance: 24)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].boundingBox.minX, 0, accuracy: 0.5)
        XCTAssertEqual(groups[0].boundingBox.maxX, 200, accuracy: 0.5)
        XCTAssertEqual(groups[0].boundingBox.maxY, 50, accuracy: 0.5)
    }
}
