import XCTest
@testable import PenSculpt

/// Selection → existing-object resolution for edit-session re-entry. The
/// spec calls for sourceStrokeIDs OVERLAP; exact set equality silently
/// downgraded near-miss re-selections to fresh lifts, re-inferring from
/// baked ink and degrading it a little more on every cycle.
final class Edit25DOverlayTests: XCTestCase {

    private func object(with ids: [UUID]) -> SculptObject {
        SculptObject(mesh: Mesh(), sourceStrokeIDs: Set(ids))
    }

    private func resolve(_ selection: Set<UUID>, _ objects: [SculptObject]) -> SculptObject? {
        Edit25DOverlay.resolveSessionObject(selection: selection, objects: objects)
    }

    func testExactMatchResolves() {
        let ids = [UUID(), UUID(), UUID()]
        let obj = object(with: ids)
        XCTAssertEqual(resolve(Set(ids), [obj])?.id, obj.id)
    }

    func testSupersetSelectionResolves() {
        // The lasso caught the shape plus a doodle beside it.
        let ids = [UUID(), UUID(), UUID()]
        let obj = object(with: ids)
        XCTAssertEqual(resolve(Set(ids + [UUID()]), [obj])?.id, obj.id)
    }

    func testSubsetSelectionResolves() {
        // The smart selector's cluster missed one of the object's strokes.
        let ids = [UUID(), UUID(), UUID()]
        let obj = object(with: ids)
        XCTAssertEqual(resolve(Set(ids.dropLast()), [obj])?.id, obj.id)
    }

    func testNoOverlapReturnsNil() {
        let obj = object(with: [UUID(), UUID()])
        XCTAssertNil(resolve(Set([UUID(), UUID()]), [obj]))
    }

    func testLargestOverlapWins() {
        let shared = UUID()
        let big = [UUID(), UUID(), shared]
        let bigObj = object(with: big)
        let smallObj = object(with: [shared])
        let selection = Set(big)   // 3 ids of bigObj, 1 of smallObj
        XCTAssertEqual(resolve(selection, [smallObj, bigObj])?.id, bigObj.id)
    }

    func testTieResolvesToMostRecentObject() {
        let shared = UUID()
        let older = object(with: [shared, UUID()])
        let newer = object(with: [shared, UUID()])
        XCTAssertEqual(resolve(Set([shared]), [older, newer])?.id, newer.id)
    }

    func testEmptySelectionReturnsNil() {
        let obj = object(with: [UUID()])
        XCTAssertNil(resolve([], [obj]))
    }
}
