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
        XCTAssertEqual(EditInputRouter.tapAction(onMesh: false, pointer: .finger), .commit)
    }

    func testTapOnMeshIsIgnored() {
        XCTAssertEqual(EditInputRouter.tapAction(onMesh: true, pointer: .finger), .ignore)
    }

    func testPencilTapOffMeshIsIgnored() {
        // Stippling dots beside the shape must never eject the user from the session.
        XCTAssertEqual(EditInputRouter.tapAction(onMesh: false, pointer: .pencil), .ignore)
    }

    func testPencilTapOnMeshIsIgnored() {
        XCTAssertEqual(EditInputRouter.tapAction(onMesh: true, pointer: .pencil), .ignore)
    }

    func testDragActionExhaustiveMatrix() {
        // Independent mirror of the precedence rules: thumb > tool > pointer.
        func expected(_ pointer: EditInputRouter.Pointer, _ onMesh: Bool,
                      _ thumb: Bool, _ tool: EditInputRouter.Tool) -> EditInputRouter.Action {
            if thumb { return .rotate }
            switch tool {
            case .deform: return .deform
            case .smooth: return .smooth
            case .eraseStroke: return .eraseStroke
            case .draw:
                if pointer == .finger { return .rotate }
                return onMesh ? .drawOnSurface : .drawOnCanvas
            }
        }

        let pointers: [EditInputRouter.Pointer] = [.pencil, .finger]
        let tools: [EditInputRouter.Tool] = [.draw, .deform, .smooth, .eraseStroke]
        for pointer in pointers {
            for onMesh in [false, true] {
                for thumb in [false, true] {
                    for tool in tools {
                        XCTAssertEqual(
                            EditInputRouter.dragAction(pointer: pointer, startedOnMesh: onMesh,
                                                       thumbRotateHeld: thumb, tool: tool),
                            expected(pointer, onMesh, thumb, tool),
                            "pointer=\(pointer) onMesh=\(onMesh) thumb=\(thumb) tool=\(tool)")
                    }
                }
            }
        }
    }
}
