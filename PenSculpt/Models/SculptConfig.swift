import Foundation

struct SculptConfig: Codable, Equatable, Sendable {
    /// Minimum curvature radius in points. Controls how smooth surface transitions are.
    var minCurvatureRadius: CGFloat = 25

    /// Grid spacing in points for the inflation mesh. Lower = smoother but more vertices.
    var gridSpacing: CGFloat = 2

    /// Stroke width used when rasterizing strokes for Vision contour detection.
    var contourStrokeWidth: CGFloat = 8

    /// Contrast adjustment for Vision contour detection (0..3). Higher = more detail.
    var contourContrast: CGFloat = 1.5

    /// Scale factor for rasterization. Higher = more precise contour detection.
    var contourRasterScale: CGFloat = 1

    /// Maximum contour points before simplification is applied.
    var contourMaxPoints: CGFloat = 500

    /// Camera tilt angle in radians. Higher = more top-down view.
    var cameraTilt: Float = 0.8

    /// Surface stroke offset along face normal to prevent z-fighting.
    var surfaceStrokeOffset: Float = 0.5

    /// Default width of surface strokes in world units.
    var surfaceStrokeWidth: Float = 8

    /// Minimum deform brush radius in world units (slider at minimum).
    var deformRadiusMin: Float = 5

    /// Maximum deform brush radius in world units (slider at maximum).
    var deformRadiusMax: Float = 80

    /// Minimum displacement strength (at slow pen speed).
    var deformMinStrength: Float = 1

    /// Maximum displacement strength (at fast pen speed).
    var deformMaxStrength: Float = 15

    /// Pen speed (in points/sec) at which maximum deformation strength is reached.
    var deformMaxSpeed: Float = 1500

    /// Default deform force (0.05...1). Slider starts here when entering distort mode.
    var deformDefaultForce: Float = 0.5

    /// Deform cursor circle line width in points.
    var deformCursorLineWidth: CGFloat = 2.5

    /// Deform cursor circle dash pattern [dash length, gap length].
    var deformCursorDash: [CGFloat] = [8, 5]

    /// Deform cursor circle opacity (0...1).
    var deformCursorOpacity: CGFloat = 0.9

    /// Number of adaptive edge-splitting passes for seam triangles.
    var seamSubdivisionPasses: Int = 5

    /// Maximum allowed t-value jump between consecutive ray cast hits.
    /// Rejects points that cross to a different surface. Normal variation is ~5-20.
    var surfaceStrokeMaxTJump: Float = 50

    /// Display mode: "shaded" for lit surface, "wireframe" for debug mesh.
    var displayMode: String = "shaded"

    static let `default` = SculptConfig()
}
