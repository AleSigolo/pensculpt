import SwiftUI
import UIKit

struct GrowthVisualization: UIViewRepresentable {
    let frame: GrowFrame
    let allStrokes: [Stroke]
    var viewBridge: ViewBridge?

    static let pulsePeriod: CFTimeInterval = 1.2
    static let sphereStrokeColor = UIColor.systemBlue.withAlphaComponent(0.7)
    static let sphereFillColor = UIColor.systemBlue.withAlphaComponent(0.08)
    static let haloColor = UIColor.systemYellow.withAlphaComponent(0.85)
    static let candidatePeak = UIColor.systemOrange.withAlphaComponent(0.65)
    static let candidateBase = UIColor.systemOrange.withAlphaComponent(0.25)

    // Subtract-mode palette: same alphas, red hue.
    static let subtractSphereStrokeColor = UIColor.systemRed.withAlphaComponent(0.7)
    static let subtractSphereFillColor = UIColor.systemRed.withAlphaComponent(0.08)
    static let subtractCandidateBase = UIColor.systemRed.withAlphaComponent(0.25)

    func makeUIView(context: Context) -> GrowthVisualizationView {
        let v = GrowthVisualizationView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: GrowthVisualizationView, context: Context) {
        uiView.frameModel = frame
        uiView.allStrokes = allStrokes
        uiView.canvasView = viewBridge?.canvasView
        uiView.setNeedsDisplay()
    }
}

final class GrowthVisualizationView: UIView {
    var frameModel: GrowFrame?
    var allStrokes: [Stroke] = []
    weak var canvasView: UIView?
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        startDisplayLink()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { displayLink?.invalidate() }

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(animationTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func animationTick() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let model = frameModel,
              let ctx = UIGraphicsGetCurrentContext() else { return }

        let center = convert(model.center)

        let sphereFill: UIColor
        let sphereStroke: UIColor
        let candidateBase: UIColor
        switch model.mode {
        case .add:
            sphereFill = GrowthVisualization.sphereFillColor
            sphereStroke = GrowthVisualization.sphereStrokeColor
            candidateBase = GrowthVisualization.candidateBase
        case .subtract:
            sphereFill = GrowthVisualization.subtractSphereFillColor
            sphereStroke = GrowthVisualization.subtractSphereStrokeColor
            candidateBase = GrowthVisualization.subtractCandidateBase
        }

        // Sphere fill
        ctx.setFillColor(sphereFill.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - model.radius, y: center.y - model.radius,
                                    width: model.radius * 2, height: model.radius * 2))

        // Sphere outline (dashed)
        ctx.setStrokeColor(sphereStroke.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokeEllipse(in: CGRect(x: center.x - model.radius, y: center.y - model.radius,
                                      width: model.radius * 2, height: model.radius * 2))
        ctx.setLineDash(phase: 0, lengths: [])

        // Halo when paused
        if model.isPaused {
            let inset: CGFloat = 4
            let r = model.radius + inset
            ctx.setStrokeColor(GrowthVisualization.haloColor.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                          width: r * 2, height: r * 2))
        }

        // Candidate pulse
        if let id = model.nextCandidateID,
           let stroke = allStrokes.first(where: { $0.id == id }),
           stroke.points.count > 1 {
            let now = CACurrentMediaTime()
            let phase = (sin((now / GrowthVisualization.pulsePeriod) * 2 * .pi) + 1) / 2
            let opacity = 0.25 + 0.4 * phase
            ctx.setStrokeColor(candidateBase
                .withAlphaComponent(CGFloat(opacity)).cgColor)
            ctx.setLineWidth(6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            ctx.move(to: convert(stroke.points[0].location))
            for p in stroke.points.dropFirst() {
                ctx.addLine(to: convert(p.location))
            }
            ctx.strokePath()
        }
    }

    /// Canvas coords → this view's coords. Falls back to identity if no canvas attached.
    private func convert(_ canvasPoint: CGPoint) -> CGPoint {
        guard let canvas = canvasView else { return canvasPoint }
        return canvas.convert(canvasPoint, to: self)
    }
}
