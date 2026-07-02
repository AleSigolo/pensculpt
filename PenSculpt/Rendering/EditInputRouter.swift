import Foundation

/// The core 2.5D interaction contract: fingers manipulate, the pen draws.
/// Pure classification so the whole routing table is unit-testable; the
/// MetalCanvasView coordinator is a thin adapter over this.
enum EditInputRouter {

    enum Pointer {
        case pencil
        case finger
    }

    enum Tool {
        case draw
        case deform
        case smooth
        case eraseStroke
    }

    enum Action: Equatable {
        case drawOnSurface
        case drawOnCanvas
        case rotate
        case deform
        case smooth
        case eraseStroke
        case commit
        case ignore
    }

    /// Routing for a single-pointer drag. `startedOnMesh` is decided once, by
    /// hit-testing the first sample of the gesture — a stroke that starts on
    /// the shape stays a surface stroke, one that starts beside it stays flat.
    static func dragAction(pointer: Pointer, startedOnMesh: Bool,
                           thumbRotateHeld: Bool, tool: Tool) -> Action {
        if thumbRotateHeld { return .rotate }
        switch tool {
        case .deform: return .deform
        case .smooth: return .smooth
        case .eraseStroke: return .eraseStroke
        case .draw:
            switch pointer {
            case .finger: return .rotate
            case .pencil: return startedOnMesh ? .drawOnSurface : .drawOnCanvas
            }
        }
    }

    /// Routing for a single tap: tapping empty canvas commits the edit session.
    static func tapAction(onMesh: Bool) -> Action {
        onMesh ? .ignore : .commit
    }
}
