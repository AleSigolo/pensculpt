import Foundation

/// The core 2.5D interaction contract: fingers manipulate, the pen draws.
/// Pure classification so the whole routing table is unit-testable; the
/// MetalCanvasView coordinator is a thin adapter over this.
///
/// Multi-finger gestures (two-finger rotate/pinch/roll) are routed by
/// UIGestureRecognizers and intentionally bypass this single-pointer table.
enum EditInputRouter {

    enum Pointer: Equatable {
        case pencil
        case finger
    }

    enum Tool: Equatable {
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
    /// hit-testing the gesture-start location (the consumer should prefer the
    /// first buffered coalesced sample when available) — a stroke that starts
    /// on the shape stays a surface stroke, one that starts beside it stays flat.
    ///
    /// All inputs are sampled once at gesture start; mid-gesture changes
    /// (thumb release, tool toggle) do not reclassify — the coordinator
    /// latches the action for the drag's lifetime.
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

    /// Routing for a single tap: a finger tap on empty canvas commits the edit
    /// session. Pencil taps never commit — a user stippling dots beside the
    /// shape must never be ejected from the session.
    static func tapAction(onMesh: Bool, pointer: Pointer) -> Action {
        (pointer == .finger && !onMesh) ? .commit : .ignore
    }
}
