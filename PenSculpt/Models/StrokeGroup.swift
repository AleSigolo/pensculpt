import Foundation

/// A cluster of strokes that are spatially close enough to be treated as
/// one drawn object by the smart selector.
struct StrokeGroup: Identifiable, Equatable {
    let id: UUID
    let strokeIDs: Set<UUID>
    let boundingBox: CGRect

    init(id: UUID = UUID(), strokeIDs: Set<UUID>, boundingBox: CGRect) {
        self.id = id
        self.strokeIDs = strokeIDs
        self.boundingBox = boundingBox
    }
}
