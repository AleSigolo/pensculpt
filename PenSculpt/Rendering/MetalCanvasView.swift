import SwiftUI
import MetalKit

/// MTKView subclass that captures Apple Pencil coalesced touches for high-fidelity strokes.
class ForceMTKView: MTKView {
    var currentForce: CGFloat = 0
    var maximumForce: CGFloat = 0
    /// Buffered coalesced touch samples (up to 240Hz with Apple Pencil).
    var coalescedSamples: [(location: CGPoint, force: CGFloat, maxForce: CGFloat)] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        bufferCoalesced(touch: touch, event: event)
        updateForce(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        bufferCoalesced(touch: touch, event: event)
        updateForce(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        currentForce = 0
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        currentForce = 0
    }

    private func bufferCoalesced(touch: UITouch, event: UIEvent?) {
        let maxForce = touch.maximumPossibleForce
        if let coalesced = event?.coalescedTouches(for: touch) {
            for ct in coalesced {
                coalescedSamples.append((location: ct.location(in: self),
                                         force: ct.force,
                                         maxForce: maxForce))
            }
        } else {
            coalescedSamples.append((location: touch.location(in: self),
                                     force: touch.force,
                                     maxForce: maxForce))
        }
    }

    private func updateForce(_ touch: UITouch) {
        guard touch.maximumPossibleForce > 0 else { return }
        currentForce = touch.force
        maximumForce = touch.maximumPossibleForce
    }
}

struct MetalCanvasView: UIViewRepresentable {
    var sculptObjects: [SculptObject]
    var activeObjectID: UUID?
    var config: SculptConfig = .default
    var isRotateMode: Bool = false
    var isDeformMode: Bool = false
    var isSmoothMode: Bool = false
    var isEraseStrokeMode: Bool = false
    var surfaceSpaceStrokes: Bool = false
    var brushSize: Float = 8
    var brushOpacity: Float = 1
    var activeColor: CodableColor = .black
    var onObjectTapped: (() -> Void)?
    var onSurfaceStrokeCompleted: ((SurfaceStroke) -> Void)?
    var onMeshDeformed: ((UUID, Mesh, [SurfaceStroke]) -> Void)?
    var onDeformCursor: (((position: CGPoint, radius: CGFloat)?) -> Void)?
    var onRendererReady: ((@escaping (UUID, Mesh, [SurfaceStroke]?) -> Void, @escaping (UUID, Mesh, [SurfaceStroke]?) -> Void, @escaping (UUID, MeshBVH) -> Void) -> Void)?
    var onRendererSetProjectionMode: ((@escaping (SculptRenderer.ProjectionMode, Bool) -> Void) -> Void)?
    var onViewReady: ((MTKView) -> Void)?

    func makeUIView(context: Context) -> ForceMTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        let view = ForceMTKView(frame: .zero, device: device)
        view.clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.depthStencilPixelFormat = .depth32Float
        view.isMultipleTouchEnabled = true

        let renderer = SculptRenderer(device: device)
        context.coordinator.renderer = renderer
        view.delegate = renderer

        onRendererReady? (
            { [weak renderer] objectID, newMesh, newStrokes in
                renderer?.replaceMesh(objectID: objectID, mesh: newMesh, surfaceStrokes: newStrokes)
            },
            { [weak renderer] objectID, newMesh, newStrokes in
                renderer?.morphMesh(objectID: objectID, mesh: newMesh, surfaceStrokes: newStrokes)
            },
            { [weak renderer] objectID, bvh in
                renderer?.cacheBVH(bvh, for: objectID)
            }
        )

        onRendererSetProjectionMode?({ [weak renderer] mode, animated in
            renderer?.setProjectionMode(mode, animated: animated)
        })

        let panGesture = UIPanGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handlePinch(_:)))
        pinchGesture.delegate = context.coordinator
        view.addGestureRecognizer(pinchGesture)

        let rotationGesture = UIRotationGestureRecognizer(target: context.coordinator,
                                                           action: #selector(Coordinator.handleRotation(_:)))
        rotationGesture.delegate = context.coordinator
        view.addGestureRecognizer(rotationGesture)

        let singlePan = UIPanGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleSinglePan(_:)))
        singlePan.minimumNumberOfTouches = 1
        singlePan.maximumNumberOfTouches = 1
        singlePan.cancelsTouchesInView = false
        view.addGestureRecognizer(singlePan)

        onViewReady?(view)
        return view
    }

    func updateUIView(_ uiView: ForceMTKView, context: Context) {
        if !context.coordinator.isCurrentlyDeforming {
            context.coordinator.renderer?.sculptObjects = sculptObjects
        }
        context.coordinator.renderer?.activeObjectID = activeObjectID
        context.coordinator.renderer?.config = config
        context.coordinator.renderer?.surfaceSpaceStrokes = surfaceSpaceStrokes
        context.coordinator.isRotateMode = isRotateMode
        context.coordinator.isDeformMode = isDeformMode
        context.coordinator.isSmoothMode = isSmoothMode
        context.coordinator.isEraseStrokeMode = isEraseStrokeMode
        context.coordinator.brushSize = brushSize
        context.coordinator.brushOpacity = brushOpacity
        context.coordinator.renderer?.brushOpacity = brushOpacity
        context.coordinator.renderer?.currentStrokeColor = activeColor
        context.coordinator.activeColor = activeColor
        context.coordinator.onObjectTapped = onObjectTapped
        context.coordinator.onSurfaceStrokeCompleted = onSurfaceStrokeCompleted
        context.coordinator.onMeshDeformed = onMeshDeformed
        context.coordinator.onDeformCursor = onDeformCursor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: SculptRenderer?
        var activeColor: CodableColor = .black
        var isRotateMode = false
        var isDeformMode = false
        var isSmoothMode = false
        var isEraseStrokeMode = false
        var brushSize: Float = 8
        var brushOpacity: Float = 1
        var onObjectTapped: (() -> Void)?
        var onSurfaceStrokeCompleted: ((SurfaceStroke) -> Void)?
        var onMeshDeformed: ((UUID, Mesh, [SurfaceStroke]) -> Void)?
        var onDeformCursor: (((position: CGPoint, radius: CGFloat)?) -> Void)?
        var isCurrentlyDeforming = false

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            applyRotation(gesture)
        }

        @objc func handleSinglePan(_ gesture: UIPanGestureRecognizer) {
            // Flush stale coalesced samples from prior gestures (taps, two-finger)
            // so they don't get misinterpreted as stroke points.
            if gesture.state == .began,
               let forceView = gesture.view as? ForceMTKView {
                forceView.coalescedSamples.removeAll()
            }
            if isRotateMode {
                applyRotation(gesture)
            } else if isDeformMode {
                handleDeform(gesture)
            } else {
                handleDraw(gesture)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            onObjectTapped?()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let renderer = renderer else { return }
            if gesture.state == .changed {
                renderer.zoom(by: Float(gesture.scale))
                gesture.scale = 1
            }
        }

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let renderer = renderer else { return }
            if gesture.state == .changed {
                renderer.rotateZ(by: Float(gesture.rotation))
                gesture.rotation = 0
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let twoFingerTypes: [UIGestureRecognizer.Type] = [
                UIPinchGestureRecognizer.self,
                UIRotationGestureRecognizer.self
            ]
            let isTwoFingerPan = { (g: UIGestureRecognizer) -> Bool in
                guard let pan = g as? UIPanGestureRecognizer else { return false }
                return pan.minimumNumberOfTouches == 2
            }
            let isMultiTouch = { (g: UIGestureRecognizer) -> Bool in
                twoFingerTypes.contains(where: { type(of: g) == $0 }) || isTwoFingerPan(g)
            }
            return isMultiTouch(gestureRecognizer) && isMultiTouch(other)
        }

        private func applyRotation(_ gesture: UIPanGestureRecognizer) {
            guard let renderer = renderer else { return }
            let translation = gesture.translation(in: gesture.view)
            renderer.rotate(dx: Float(translation.x), dy: Float(translation.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        private func handleDeform(_ gesture: UIPanGestureRecognizer) {
            guard let renderer = renderer else { return }
            let location = gesture.location(in: gesture.view)
            let viewSize = gesture.view?.bounds.size ?? .zero
            let sliderT = (brushSize - 1) / 19  // normalize 1...20 to 0...1
            let worldRadius = renderer.config.deformRadiusMin + sliderT * (renderer.config.deformRadiusMax - renderer.config.deformRadiusMin)

            if gesture.state == .began || gesture.state == .changed {
                isCurrentlyDeforming = true
                if isSmoothMode {
                    renderer.smoothMesh(at: location, viewSize: viewSize,
                                        strength: brushOpacity, radius: worldRadius)
                } else {
                    let velocity = gesture.velocity(in: gesture.view)
                    let speed = Float(hypot(velocity.x, velocity.y))
                    let config = renderer.config
                    let t = min(speed / config.deformMaxSpeed, 1.0)
                    let baseStrength = config.deformMinStrength + t * (config.deformMaxStrength - config.deformMinStrength)
                    let strength = baseStrength * brushOpacity
                    renderer.deformMesh(at: location, viewSize: viewSize, strength: strength,
                                         radius: worldRadius, screenVelocity: velocity)
                }

                let screenRadius = CGFloat(worldRadius) * viewSize.height / CGFloat(2 * renderer.combinedRadius)
                onDeformCursor?((position: location, radius: screenRadius))
            } else if gesture.state == .ended || gesture.state == .cancelled {
                isCurrentlyDeforming = false
                onDeformCursor?(nil)
                if let activeID = renderer.activeObjectID,
                   let idx = renderer.sculptObjects.firstIndex(where: { $0.id == activeID }) {
                    let obj = renderer.sculptObjects[idx]
                    onMeshDeformed?(activeID, obj.mesh, obj.surfaceStrokes)
                }
            }
        }

        private func handleDraw(_ gesture: UIPanGestureRecognizer) {
            guard let renderer = renderer,
                  let forceView = gesture.view as? ForceMTKView else { return }
            let viewSize = forceView.bounds.size

            if isEraseStrokeMode {
                if gesture.state == .began || gesture.state == .changed {
                    let samples = forceView.coalescedSamples
                    forceView.coalescedSamples.removeAll()
                    for sample in samples {
                        if let result = renderer.hitTest(screenPoint: sample.location, viewSize: viewSize),
                           let activeID = renderer.activeObjectID,
                           let idx = renderer.sculptObjects.firstIndex(where: { $0.id == activeID }) {
                            renderer.eraseNearestStroke(at: result.point, objectIndex: idx,
                                                        threshold: brushSize * 2)
                        }
                    }
                } else if gesture.state == .ended || gesture.state == .cancelled {
                    forceView.coalescedSamples.removeAll()
                    if let activeID = renderer.activeObjectID,
                       let idx = renderer.sculptObjects.firstIndex(where: { $0.id == activeID }) {
                        let obj = renderer.sculptObjects[idx]
                        onMeshDeformed?(activeID, obj.mesh, obj.surfaceStrokes)
                    }
                }
                return
            }

            if gesture.state == .began || gesture.state == .changed {
                let samples = forceView.coalescedSamples
                forceView.coalescedSamples.removeAll()
                for sample in samples {
                    if let result = renderer.hitTest(screenPoint: sample.location, viewSize: viewSize),
                       renderer.isTContinuous(result.t) {
                        renderer.currentStrokePoints.append(result.point)
                        renderer.currentStrokeWidths.append(pressureWidth(force: sample.force,
                                                                           maxForce: sample.maxForce))
                        renderer.lastHitT = result.t
                    }
                }
            } else if gesture.state == .ended || gesture.state == .cancelled {
                forceView.coalescedSamples.removeAll()
                if renderer.currentStrokePoints.count > 1 {
                    let stroke = SurfaceStroke(points: renderer.currentStrokePoints,
                                                widths: renderer.currentStrokeWidths,
                                                opacity: renderer.brushOpacity,
                                                color: activeColor)
                    if let activeID = renderer.activeObjectID,
                       let idx = renderer.sculptObjects.firstIndex(where: { $0.id == activeID }) {
                        renderer.sculptObjects[idx].surfaceStrokes.append(stroke)
                    }
                    onSurfaceStrokeCompleted?(stroke)
                }
                renderer.currentStrokePoints.removeAll()
                renderer.currentStrokeWidths.removeAll()
                renderer.lastHitT = 0
            }
        }

        private func pressureWidth(force: CGFloat, maxForce: CGFloat) -> Float {
            guard maxForce > 0 else { return brushSize }
            let normalized = Float(force / maxForce)
            return brushSize * (0.05 + 0.95 * normalized)
        }
    }
}
