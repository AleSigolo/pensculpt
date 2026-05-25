import Foundation

struct TooltipContent: Equatable {
    let title: String
    let subtitle: String?
}

enum TooltipID: String, CaseIterable {
    // Drawing — FloatingToolbar
    case colorSwatch
    case undo
    case redo
    case toolPen
    case toolEraser
    case toolPixelEraser
    case clear
    case exportImage

    // Drawing — overlay
    case toolbarCollapse
    case deselect

    // Drawing — nav bar
    case modeToggle
    case autosaveToggle
    case save

    // Shared
    case tooltipsToggle

    // Sculpt — toolbar topLeading
    case sculptClose
    case sculptReinfer
    case sculptReinferMorph
    case sculptInflationMode
    case sculptAutoProject
    case sculptExport

    // Sculpt — bottom toolbar
    case sculptColorSwatch
    case sculptSurfaceSpace

    // Sculpt — corners
    case sculptRotate
    case sculptPerspective
    case sculptFOV
    case sculptEraser
    case sculptDeform

    var content: TooltipContent {
        switch self {
        case .colorSwatch:        return .init(title: "Color", subtitle: "Tap to change the active drawing color")
        case .undo:               return .init(title: "Undo", subtitle: nil)
        case .redo:               return .init(title: "Redo", subtitle: nil)
        case .toolPen:            return .init(title: "Pen", subtitle: "Draw with the pen tool")
        case .toolEraser:         return .init(title: "Eraser", subtitle: "Erase whole strokes")
        case .toolPixelEraser:    return .init(title: "Pixel eraser", subtitle: "Erase parts of strokes pixel by pixel")
        case .clear:              return .init(title: "Clear", subtitle: "Remove all strokes from the canvas")
        case .exportImage:        return .init(title: "Share", subtitle: "Export the drawing as an image")
        case .toolbarCollapse:    return .init(title: "Toolbar", subtitle: "Show or hide the drawing toolbar")
        case .deselect:           return .init(title: "Deselect", subtitle: "Clear the current stroke selection")
        case .modeToggle:         return .init(title: "Selection mode", subtitle: "Drag to lasso · Hold to grow selection")
        case .autosaveToggle:     return .init(title: "Autosave", subtitle: "Save changes automatically as you draw")
        case .save:               return .init(title: "Save", subtitle: nil)
        case .tooltipsToggle:     return .init(title: "Tooltips", subtitle: "Show or hide button hints on hover")
        case .sculptClose:        return .init(title: "Close", subtitle: "Return to the 2D canvas")
        case .sculptReinfer:      return .init(title: "Re-infer shape", subtitle: "Rebuild the 3D shape from the current strokes")
        case .sculptReinferMorph: return .init(title: "Morph re-infer (beta)", subtitle: "Smoothly morph the current shape into the re-inferred one")
        case .sculptInflationMode: return .init(title: "Inflation", subtitle: "Switch between organic (curved) and straight (cube) shape")
        case .sculptAutoProject:  return .init(title: "Auto-project strokes", subtitle: "Bring surface strokes back to 2D on exit")
        case .sculptExport:       return .init(title: "Share", subtitle: "Export an image or 3D mesh")
        case .sculptColorSwatch:  return .init(title: "Color", subtitle: "Active color for new surface strokes")
        case .sculptSurfaceSpace: return .init(title: "Stroke space", subtitle: "Toggle strokes anchored to the surface or to the screen")
        case .sculptRotate:       return .init(title: "Rotate", subtitle: "Hold and drag to rotate the 3D view")
        case .sculptPerspective:  return .init(title: "Perspective", subtitle: "Toggle between orthographic and perspective projection")
        case .sculptFOV:          return .init(title: "Field of view", subtitle: "Adjust how strong the perspective looks")
        case .sculptEraser:       return .init(title: "Eraser / Smoother", subtitle: "Erases strokes; while in deform mode, smooths the surface")
        case .sculptDeform:       return .init(title: "Deform", subtitle: "Push and pull the 3D surface with the Pencil")
        }
    }
}
