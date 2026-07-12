import XCTest
import UIKit
@testable import PenSculpt

/// Renders pipeline stages to images for visual inspection.
final class PipelineVisualTests: XCTestCase {

    private let outputDir = NSTemporaryDirectory() + "PenSculptDiag/"
    private let imageSize = CGSize(width: 600, height: 800)

    override func setUp() {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - Sample shapes

    /// Vase: two symmetric curves, rounded bottom, open top
    private var vaseStrokes: [Stroke] {
        var leftPoints: [StrokePoint] = []
        var rightPoints: [StrokePoint] = []
        let steps = 50
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = 100 + t * 600 // y from 100 to 700

            // Vase profile: wide at top, narrow neck at 30%, wide body, round bottom
            let profile: CGFloat
            if t < 0.05 {
                // Rounded bottom: radius goes from 0 to ~60
                profile = 60 * sin(t / 0.05 * .pi / 2)
            } else if t < 0.4 {
                // Body widens
                profile = 60 + (t - 0.05) / 0.35 * 40
            } else if t < 0.6 {
                // Neck narrows
                let nt = (t - 0.4) / 0.2
                profile = 100 - nt * 60
            } else {
                // Flare to opening
                let ot = (t - 0.6) / 0.4
                profile = 40 + ot * 50
            }

            let centerX: CGFloat = 300
            leftPoints.append(StrokePoint(
                location: CGPoint(x: centerX - profile, y: y),
                pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
            rightPoints.append(StrokePoint(
                location: CGPoint(x: centerX + profile, y: y),
                pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
        }
        return [Stroke(points: leftPoints), Stroke(points: rightPoints)]
    }

    // MARK: - Visual diagnostic

    func testVisualizeVasePipeline() {
        runDiagnostic(name: "vase", strokes: vaseStrokes)
    }

    // MARK: - Circle (should produce a sphere-like shape)

    private var circleStrokes: [Stroke] {
        var points: [StrokePoint] = []
        let steps = 60
        let cx: CGFloat = 300, cy: CGFloat = 400, r: CGFloat = 150
        for i in 0...steps {
            let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
            points.append(StrokePoint(
                location: CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle)),
                pressure: 1, tilt: 0, azimuth: 0, timestamp: CGFloat(i) * 0.01))
        }
        return [Stroke(points: points)]
    }

    func testVisualizeCircle() {
        runDiagnostic(name: "circle", strokes: circleStrokes)
    }

    // MARK: - Square (should produce a cylinder-like shape)

    private var squareStrokes: [Stroke] {
        // Dense points along edges, like PencilKit would capture
        interpolatedStroke(corners: [
            (200, 200), (400, 200), (400, 600), (200, 600), (200, 200)
        ], pointsPerEdge: 20)
    }

    func testVisualizeSquare() {
        runDiagnostic(name: "square", strokes: squareStrokes)
    }

    // MARK: - Triangle (should produce a cone-like shape)

    private var triangleStrokes: [Stroke] {
        interpolatedStroke(corners: [
            (300, 150), (450, 550), (150, 550), (300, 150)
        ], pointsPerEdge: 20)
    }

    func testVisualizeTriangle() {
        runDiagnostic(name: "triangle", strokes: triangleStrokes)
    }

    // MARK: - Cylinder (two parallel vertical lines)

    private var cylinderStrokes: [Stroke] {
        var left: [StrokePoint] = [], right: [StrokePoint] = []
        let steps = 30
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = 150 + t * 500
            left.append(StrokePoint(location: CGPoint(x: 200, y: y), pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
            right.append(StrokePoint(location: CGPoint(x: 400, y: y), pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
        }
        return [Stroke(points: left), Stroke(points: right)]
    }

    func testVisualizeCylinder() {
        runDiagnostic(name: "cylinder", strokes: cylinderStrokes)
    }

    // MARK: - Cone (two converging lines)

    private var coneStrokes: [Stroke] {
        var left: [StrokePoint] = [], right: [StrokePoint] = []
        let steps = 30
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = 150 + t * 500
            let halfWidth = 150 * (1 - t) // narrows from 150 to 0
            left.append(StrokePoint(location: CGPoint(x: 300 - halfWidth, y: y), pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
            right.append(StrokePoint(location: CGPoint(x: 300 + halfWidth, y: y), pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
        }
        return [Stroke(points: left), Stroke(points: right)]
    }

    func testVisualizeCone() {
        runDiagnostic(name: "cone", strokes: coneStrokes)
    }

    // MARK: - Egg/Oval (ellipse)

    private var ovalStrokes: [Stroke] {
        var points: [StrokePoint] = []
        let steps = 60
        let cx: CGFloat = 300, cy: CGFloat = 400
        let rx: CGFloat = 100, ry: CGFloat = 200
        for i in 0...steps {
            let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
            points.append(StrokePoint(
                location: CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle)),
                pressure: 1, tilt: 0, azimuth: 0, timestamp: CGFloat(i) * 0.01))
        }
        return [Stroke(points: points)]
    }

    func testVisualizeOval() {
        runDiagnostic(name: "oval", strokes: ovalStrokes)
    }

    // MARK: - Hand-drawn (noisy) circle

    private var handDrawnCircleStrokes: [Stroke] {
        // Simulates a real hand-drawn circle: 200 points, with jitter
        var points: [StrokePoint] = []
        let steps = 200
        let cx: CGFloat = 300, cy: CGFloat = 400, r: CGFloat = 120
        for i in 0...steps {
            let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let jitterR = CGFloat.random(in: -5...5)
            let jitterA = CGFloat.random(in: -0.02...0.02)
            points.append(StrokePoint(
                location: CGPoint(x: cx + (r + jitterR) * cos(angle + jitterA),
                                   y: cy + (r + jitterR) * sin(angle + jitterA)),
                pressure: CGFloat.random(in: 0.8...1.0),
                tilt: 0, azimuth: 0, timestamp: CGFloat(i) * 0.005))
        }
        return [Stroke(points: points)]
    }

    func testVisualizeHandDrawnCircle() {
        runDiagnostic(name: "hand_circle", strokes: handDrawnCircleStrokes)
    }

    // MARK: - Hand-drawn vase (two noisy strokes)

    private var handDrawnVaseStrokes: [Stroke] {
        var leftPoints: [StrokePoint] = []
        var rightPoints: [StrokePoint] = []
        let steps = 100
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = 100 + t * 600
            let profile: CGFloat
            if t < 0.05 {
                profile = 60 * sin(t / 0.05 * .pi / 2)
            } else if t < 0.4 {
                profile = 60 + (t - 0.05) / 0.35 * 40
            } else if t < 0.6 {
                let nt = (t - 0.4) / 0.2
                profile = 100 - nt * 60
            } else {
                let ot = (t - 0.6) / 0.4
                profile = 40 + ot * 50
            }
            let jitter = CGFloat.random(in: -3...3)
            leftPoints.append(StrokePoint(
                location: CGPoint(x: 300 - profile + jitter, y: y + CGFloat.random(in: -2...2)),
                pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
            rightPoints.append(StrokePoint(
                location: CGPoint(x: 300 + profile + jitter, y: y + CGFloat.random(in: -2...2)),
                pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
        }
        return [Stroke(points: leftPoints), Stroke(points: rightPoints)]
    }

    func testVisualizeHandDrawnVase() {
        runDiagnostic(name: "hand_vase", strokes: handDrawnVaseStrokes)
    }

    // MARK: - Multi-part figure (closed-stroke person: head/body/arms/legs)

    private var figureStrokes: [Stroke] {
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                     steps: Int = 48) -> Stroke {
            var points: [StrokePoint] = []
            for i in 0...steps {
                let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
                points.append(StrokePoint(
                    location: CGPoint(x: cx + rx * cos(angle), y: cy + ry * sin(angle)),
                    pressure: 1, tilt: 0, azimuth: 0, timestamp: CGFloat(i) * 0.01))
            }
            return Stroke(points: points)
        }
        return [
            ellipse(cx: 300, cy: 200, rx: 60, ry: 60),    // head
            ellipse(cx: 300, cy: 400, rx: 90, ry: 150),   // body (overlaps head at y≈250)
            ellipse(cx: 195, cy: 380, rx: 25, ry: 90),    // left arm
            ellipse(cx: 405, cy: 380, rx: 25, ry: 90),    // right arm
            ellipse(cx: 260, cy: 610, rx: 30, ry: 80),    // left leg
            ellipse(cx: 340, cy: 610, rx: 30, ry: 80),    // right leg
        ]
    }

    func testVisualizeFigure() {
        runDiagnostic(name: "figure", strokes: figureStrokes)
    }

    func testCircleDepthRatio() {
        let strokes = handDrawnCircleStrokes
        let obj = ShapeInflater.sculpt(from: strokes)
        let positions = obj.mesh.vertices.map(\.position)
        let xs = positions.map(\.x), ys = positions.map(\.y), zs = positions.map(\.z)
        let xRange = xs.max()! - xs.min()!
        let yRange = ys.max()! - ys.min()!
        let zRange = zs.max()! - zs.min()!
        print("🔵 Circle mesh: X=\(xRange) Y=\(yRange) Z=\(zRange)")
        print("🔵 Z/X ratio: \(zRange/xRange) (should be ~1.0 for sphere)")
        print("🔵 Z/Y ratio: \(zRange/yRange) (should be ~1.0 for sphere)")
        // For a sphere, all three extents should be roughly equal
        XCTAssertGreaterThan(zRange / xRange, 0.5, "Z depth should be at least 50% of X width for a sphere")
    }

    // MARK: - Helpers

    /// Creates a single stroke with dense interpolated points along edges.
    private func interpolatedStroke(corners: [(CGFloat, CGFloat)], pointsPerEdge: Int) -> [Stroke] {
        var points: [StrokePoint] = []
        var t: CGFloat = 0
        for i in 0..<(corners.count - 1) {
            let from = corners[i], to = corners[i + 1]
            for j in 0..<pointsPerEdge {
                let f = CGFloat(j) / CGFloat(pointsPerEdge)
                let x = from.0 + (to.0 - from.0) * f
                let y = from.1 + (to.1 - from.1) * f
                points.append(StrokePoint(location: CGPoint(x: x, y: y),
                                           pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
                t += 0.01
            }
        }
        // Add final point
        let last = corners.last!
        points.append(StrokePoint(location: CGPoint(x: last.0, y: last.1),
                                   pressure: 1, tilt: 0, azimuth: 0, timestamp: t))
        return [Stroke(points: points)]
    }

    // MARK: - Shared diagnostic runner

    private func runDiagnostic(name: String, strokes: [Stroke]) {
        let allPoints = strokes.flatMap { $0.points.map(\.location) }
        let sculptObject = ShapeInflater.sculpt(from: strokes)
        let contour = ContourExtractor.extract(from: strokes)

        // Render pipeline overlay
        let pipelineImage = renderPipelineOverlay(allPoints: allPoints, name: name, sculptObject: sculptObject, contour: contour)
        save(pipelineImage, name: "\(name)_pipeline")

        // Render mesh profile
        let profileImage = renderMeshProfile(sculptObject.mesh)
        save(profileImage, name: "\(name)_mesh_profile")

        print("📊 \(name): mesh \(sculptObject.mesh.vertexCount)v/\(sculptObject.mesh.faceCount)f, contour \(contour.count)pts")

        XCTAssertFalse(sculptObject.mesh.isEmpty, "\(name) should produce a mesh")

        if !sculptObject.mesh.isEmpty {
            let positions = sculptObject.mesh.vertices.map(\.position)
            let xs = positions.map(\.x), ys = positions.map(\.y), zs = positions.map(\.z)
            let xRange = (xs.max()! - xs.min()!)
            let yRange = (ys.max()! - ys.min()!)
            let zRange = (zs.max()! - zs.min()!)
            print("📐 \(name) extent: X=\(String(format:"%.0f", xRange)) Y=\(String(format:"%.0f", yRange)) Z=\(String(format:"%.0f", zRange)) ratio Z/X=\(String(format:"%.2f", zRange/xRange))")
        }
    }

    private func save(_ image: UIImage, name: String) {
        let path = outputDir + "\(name).png"
        if let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: path))
            print("📸 \(path)")
        }
    }

    private func renderPipelineOverlay(allPoints: [CGPoint], name: String, sculptObject: SculptObject, contour: [CGPoint] = []) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { ctx in
            let gc = ctx.cgContext
            gc.setFillColor(UIColor.white.cgColor)
            gc.fill(CGRect(origin: .zero, size: imageSize))

            // Stroke points
            gc.setFillColor(UIColor.black.cgColor)
            for p in allPoints {
                gc.fillEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
            }

            // Vision contour (green polygon)
            if contour.count > 2 {
                gc.setStrokeColor(UIColor.green.cgColor)
                gc.setLineWidth(2)
                gc.beginPath()
                gc.move(to: contour[0])
                for p in contour.dropFirst() { gc.addLine(to: p) }
                gc.closePath()
                gc.strokePath()
            }

            // Title
            let title = "\(name): \(sculptObject.mesh.vertexCount)v/\(sculptObject.mesh.faceCount)f, contour \(contour.count)pts"
            (title as NSString).draw(at: CGPoint(x: 10, y: 10),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.darkGray])
        }
    }

    /// Renders a side-view profile of the mesh (Y vs XZ-radius) to visualize the shape.
    private func renderMeshProfile(_ mesh: Mesh) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600))
        return renderer.image { ctx in
            let gc = ctx.cgContext
            gc.setFillColor(UIColor.white.cgColor)
            gc.fill(CGRect(origin: .zero, size: CGSize(width: 400, height: 600)))

            guard !mesh.isEmpty else { return }

            let ys = mesh.vertices.map { $0.position.y }
            let radii = mesh.vertices.map { hypot($0.position.x, $0.position.z) }
            guard let minY = ys.min(), let maxY = ys.max(),
                  let maxR = radii.max(), maxR > 0, maxY > minY else { return }

            // Collect (y, maxRadius) pairs per ring
            var ringData: [(y: Float, radius: Float)] = []
            let uniqueYs = Set(ys).sorted()
            for y in uniqueYs {
                let maxRAtY = zip(ys, radii).filter { $0.0 == y }.map(\.1).max() ?? 0
                ringData.append((y, maxRAtY))
            }

            // Scale to fit in 400x600
            let scaleY = 500.0 / Float(maxY - minY)
            let scaleX = 150.0 / Float(maxR)
            let centerX: Float = 200

            // Draw profile outline
            gc.setStrokeColor(UIColor.blue.cgColor)
            gc.setLineWidth(2)

            // Right side
            gc.beginPath()
            for (i, ring) in ringData.enumerated() {
                let x = CGFloat(centerX + ring.radius * scaleX)
                let y = CGFloat(50 + (ring.y - minY) * scaleY)
                if i == 0 { gc.move(to: CGPoint(x: x, y: y)) }
                else { gc.addLine(to: CGPoint(x: x, y: y)) }
            }
            gc.strokePath()

            // Left side (mirror)
            gc.beginPath()
            for (i, ring) in ringData.enumerated() {
                let x = CGFloat(centerX - ring.radius * scaleX)
                let y = CGFloat(50 + (ring.y - minY) * scaleY)
                if i == 0 { gc.move(to: CGPoint(x: x, y: y)) }
                else { gc.addLine(to: CGPoint(x: x, y: y)) }
            }
            gc.strokePath()

            // Center axis
            gc.setStrokeColor(UIColor.red.withAlphaComponent(0.3).cgColor)
            gc.setLineWidth(1)
            gc.beginPath()
            gc.move(to: CGPoint(x: CGFloat(centerX), y: 50))
            gc.addLine(to: CGPoint(x: CGFloat(centerX), y: 550))
            gc.strokePath()

            // Label
            let label = "Mesh profile (\(ringData.count) rings)"
            (label as NSString).draw(at: CGPoint(x: 10, y: 570),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.gray])
        }
    }
}
