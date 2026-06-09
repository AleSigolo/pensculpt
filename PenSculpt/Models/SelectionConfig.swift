import Foundation

/// Tunable parameters for selection gestures. First-guess values — tune on a
/// physical iPad (smart-grow feel cannot be judged in the simulator).
enum SelectionConfig {
    /// Max ink gap (points) for two strokes to be treated as one object.
    static let clusterLinkDistance: CGFloat = 24
    /// Reach-radius expansion speed in points per second.
    static let growthRate: CGFloat = 700
    /// Stationary time (seconds) before smart-grow activates from a lasso touch.
    static let holdDelay: TimeInterval = 0.3
    /// Movement tolerance (points) distinguishing a drag (lasso) from a hold (smart).
    static let moveSlop: CGFloat = 10
}
