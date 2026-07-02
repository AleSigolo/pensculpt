import XCTest
@testable import PenSculpt

final class EditInputRouterTests: XCTestCase {

    func testThumbButtonAlwaysRotates() {
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: true,
                                                  thumbRotateHeld: true, tool: .draw), .rotate)
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: false,
                                                  thumbRotateHeld: true, tool: .deform), .rotate)
    }

    func testPencilOnMeshDrawsOnSurface() {
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: true,
                                                  thumbRotateHeld: false, tool: .draw),
                       .drawOnSurface)
    }

    func testPencilOffMeshDrawsOnCanvas() {
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: false,
                                                  thumbRotateHeld: false, tool: .draw),
                       .drawOnCanvas)
    }

    func testToolsOverrideDrawing() {
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: true,
                                                  thumbRotateHeld: false, tool: .deform), .deform)
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: true,
                                                  thumbRotateHeld: false, tool: .smooth), .smooth)
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .pencil, startedOnMesh: true,
                                                  thumbRotateHeld: false, tool: .eraseStroke),
                       .eraseStroke)
    }

    func testFingerDragRotates() {
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .finger, startedOnMesh: true,
                                                  thumbRotateHeld: false, tool: .draw), .rotate)
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .finger, startedOnMesh: false,
                                                  thumbRotateHeld: false, tool: .draw), .rotate)
    }

    func testFingerDragWithToolStillUsesTool() {
        // Deform with a finger is allowed — the tool toggle is an explicit choice.
        XCTAssertEqual(EditInputRouter.dragAction(pointer: .finger, startedOnMesh: true,
                                                  thumbRotateHeld: false, tool: .deform), .deform)
    }

    func testTapOffMeshCommits() {
        XCTAssertEqual(EditInputRouter.tapAction(onMesh: false), .commit)
    }

    func testTapOnMeshIsIgnored() {
        XCTAssertEqual(EditInputRouter.tapAction(onMesh: true), .ignore)
    }
}
