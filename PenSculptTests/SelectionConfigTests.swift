import XCTest
@testable import PenSculpt

final class SelectionConfigTests: XCTestCase {

    func testDefaultsAreSane() {
        XCTAssertGreaterThan(SelectionConfig.clusterLinkDistance, 0)
        XCTAssertGreaterThan(SelectionConfig.growthRate, 0)
        XCTAssertGreaterThan(SelectionConfig.holdDelay, 0)
        XCTAssertGreaterThan(SelectionConfig.moveSlop, 0)
    }

    func testStrategyKindHasTwoCases() {
        XCTAssertNotEqual(SelectionStrategyKind.lasso, SelectionStrategyKind.smart)
    }
}
