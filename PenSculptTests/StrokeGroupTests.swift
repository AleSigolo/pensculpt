import XCTest
@testable import PenSculpt

final class StrokeGroupTests: XCTestCase {

    func testStoresStrokeIDsAndBox() {
        let a = UUID(), b = UUID()
        let group = StrokeGroup(strokeIDs: [a, b],
                                boundingBox: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(group.strokeIDs, [a, b])
        XCTAssertEqual(group.boundingBox, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testHasStableIdentity() {
        let id = UUID()
        let group = StrokeGroup(id: id, strokeIDs: [], boundingBox: .zero)
        XCTAssertEqual(group.id, id)
    }
}
