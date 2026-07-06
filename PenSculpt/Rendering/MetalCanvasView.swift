import SwiftUI
import MetalKit
import simd

/// MTKView subclass that captures Apple Pencil coalesced touches for high-fidelity strokes.
class ForceMTKView: MTKView {
    var currentForce: CGFloat = 0
    var maximumForce: CGFloat = 0
    /// Buffered coalesced touch samples (up to 240Hz with Apple Pencil).
    var coalescedSamples: [(location: CGPoint, force: CGFloat, maxForce: CGFloat,
                            timestamp: TimeInterval)] = []
    /// Whether the current touch sequence is Apple Pencil input.
    var lastTouchWasPencil = false
    /// Exact touch-down point of the current sequence. Gesture recognizers
    /// fire ~10pt after touch-down; classification (on-mesh vs off-mesh)
    /// must use the true start point, not the recognizer's location.
    var lastTouchDownLocation: CGPoint?
    /// Peak number of simultaneous touches in the current gesture. System
    /// gestures (three-finger undo) land here as multi-touch sequences whose
    /// individual touches can read as clean taps — tap-to-commit must only
    /// honor genuinely single-finger gestures.
    private(set) var gesturePeakTouchCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        let allCount = event?.allTouches?.count ?? touches.count
        // A fresh sequence starts when these are the only touches on screen.
        if allCount == touches.count {
            gesturePeakTouchCount = 0
        }
        gesturePeakTouchCount = max(gesturePeakTouchCount, allCount)
        // A new touch sequence begins: flush leftovers from prior gestures
        // (taps, two-finger rotate/pinch) BEFORE buffering this touch, so
        // stale samples never leak into the new stroke while its head —
        // everything buffered before the pan recognizer fires — survives.
        coalescedSamples.removeAll()
        lastTouchWasPencil = touch.type == .pencil
        lastTouchDownLocation = touch.location(in: self)
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
                                         maxForce: maxForce,
                                         timestamp: ct.timestamp))
            }
        } else {
            coalescedSamples.append((location: touch.location(in: self),
                                     force: touch.force,
                                     maxForce: maxForce,
                                     timestamp: touch.timestamp))
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
    var brushSize: Float = 8
    var brushOpacity: Float = 1
    var onObjectTapped: (() -> Void)?
    var onSurfaceStrokeCompleted: ((SurfaceStroke) -> Void)?
    var onMeshDeformed: ((UUID, Mesh, [SurfaceStroke]) -> Void)?
    var onDeformCursor: (((position: CGPoint, radius: CGFloat)?) -> Void)?
    var onRendererReady: ((@escaping (UUID, Mesh, [SurfaceStroke]?) -> Void, @escaping (UUID, Mesh, [SurfaceStroke]?) -> Void, @escaping (UUID, MeshBVH) -> Void) -> Void)?
    /// Present when hosted by Edit25DOverlay: configures the in-place camera
    /// and unlocks edit-mode routing (off-mesh drawing, tap-to-commit).
    struct EditSession: Equatable {
        var objectID: UUID
        var pivot: SIMD3<Float>
        var initialOrientation: simd_quatf
        var initialScale: Float
    }
    var editSession: EditSession?
    /// A flat 2D stroke was drawn beside the shape (canvas coordinates).
    var onCanvasStrokeCompleted: ((Stroke) -> Void)?
    /// Reported at the end of every rotate/pinch gesture so the host can bake.
    var onEditTransformChanged: ((simd_quatf, Float) -> Void)?
    /// User tapped empty canvas — commit the session.
    var onCommitRequested: (() -> Void)?

    func makeUIView(context: Context) -> ForceMTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        let view = ForceMTKView(frame: .zero, device: device)
        if editSession != nil {
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.isOpaque = false
            view.layer.isOpaque = false
            view.backgroundColor = .clear
        } else {
            view.clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)
        }
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

        return view
    }

    func updateUIView(_ uiView: ForceMTKView, context: Context) {
        if let session = editSession, context.coordinator.appliedEditSessionID != session.objectID,
           let renderer = context.coordinator.renderer {
            context.coordinator.appliedEditSessionID = session.objectID
            renderer.editPivot = session.pivot
            renderer.rotation = session.initialOrientation
            renderer.modelScale = session.initialScale
        }
        if !context.coordinator.isCurrentlyDeforming {
            context.coordinator.renderer?.sculptObjects = sculptObjects
        }
        context.coordinator.renderer?.activeObjectID = activeObjectID
        context.coordinator.renderer?.config = config
        context.coordinator.isRotateMode = isRotateMode
        context.coordinator.isDeformMode = isDeformMode
        context.coordinator.isSmoothMode = isSmoothMode
        context.coordinator.isEraseStrokeMode = isEraseStrokeMode
        context.coordinator.brushSize = brushSize
        context.coordinator.brushOpacity = brushOpacity
        context.coordinator.renderer?.brushOpacity = brushOpacity
        context.coordinator.onObjectTapped = onObjectTapped
        context.coordinator.onSurfaceStrokeCompleted = onSurfaceStrokeCompleted
        context.coordinator.onMeshDeformed = onMeshDeformed
        context.coordinator.onDeformCursor = onDeformCursor
        context.coordinator.onCanvasStrokeCompleted = onCanvasStrokeCompleted
        context.coordinator.onEditTransformChanged = onEditTransformChanged
        context.coordinator.onCommitRequested = onCommitRequested
        context.coordinator.isEditSession = editSession != nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: SculptRenderer?
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
        var appliedEditSessionID: UUID?
        var isEditSession = false
        var onCanvasStrokeCompleted: ((Stroke) -> Void)?
        var onEditTransformChanged: ((simd_quatf, Float) -> Void)?
        var onCommitRequested: (() -> Void)?
        /// Resolved once per drag from the gesture's first sample.
        private var activeDragAction: EditInputRouter.Action?
        /// Raw samples of an in-progress flat canvas stroke.
        private var canvasStrokeSamples: [(location: CGPoint, force: CGFloat,
                                           maxForce: CGFloat, timestamp: TimeInterval)] = []

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            applyRotation(gesture)
            if gesture.state == .ended || gesture.state == .cancelled {
                reportEditTransform()
            }
        }

        @objc func handleSinglePan(_ gesture: UIPanGestureRecognizer) {
            // Stale samples from prior gestures were already flushed in
            // ForceMTKView.touchesBegan; the buffer now holds only this
            // stroke's head (samples between touch-down and pan recognition),
            // which must NOT be discarded here.
            if gesture.state == .began {
                activeDragAction = nil
            }

            if !isEditSession {
                if isRotateMode {
                    applyRotation(gesture)
                } else if isDeformMode {
                    handleDeform(gesture)
                } else {
                    handleDraw(gesture)
                }
                return
            }

            guard let forceView = gesture.view as? ForceMTKView, let renderer = renderer else { return }

            if activeDragAction == nil {
                let pointer: EditInputRouter.Pointer = forceView.lastTouchWasPencil ? .pencil : .finger
                let tool: EditInputRouter.Tool = isDeformMode
                    ? (isSmoothMode ? .smooth : .deform)
                    : (isEraseStrokeMode ? .eraseStroke : .draw)
                let startPoint = forceView.lastTouchDownLocation
                    ?? gesture.location(in: forceView)
                let onMesh = renderer.hitTest(screenPoint: startPoint,
                                              viewSize: forceView.bounds.size) != nil
                activeDragAction = EditInputRouter.dragAction(
                    pointer: pointer, startedOnMesh: onMesh,
                    thumbRotateHeld: isRotateMode, tool: tool)
            }

            switch activeDragAction {
            case .rotate:
                applyRotation(gesture)
                if gesture.state == .ended || gesture.state == .cancelled {
                    reportEditTransform()
                }
            case .deform, .smooth:
                handleDeform(gesture)
            case .eraseStroke, .drawOnSurface:
                handleDraw(gesture)
            case .drawOnCanvas:
                handleCanvasDraw(gesture, forceView: forceView)
            case .commit, .ignore, .none:
                break
            }

            if gesture.state == .ended || gesture.state == .cancelled {
                activeDragAction = nil
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard isEditSession else { onObjectTapped?(); return }
            guard let renderer = renderer, let view = gesture.view else { return }
            // A single finger of a system multi-touch gesture (three-finger
            // undo) can read as a clean tap here — and would silently COMMIT
            // the session right before the undo fires (manual check 13:
            // "three-finger tap baked the shape"). Only a genuinely
            // single-finger gesture may commit.
            if let force = view as? ForceMTKView, force.gesturePeakTouchCount > 1 {
                return
            }
            let pointer: EditInputRouter.Pointer =
                (view as? ForceMTKView)?.lastTouchWasPencil == true ? .pencil : .finger
            let onMesh = renderer.hitTest(screenPoint: gesture.location(in: view),
                                          viewSize: view.bounds.size) != nil
            if EditInputRouter.tapAction(onMesh: onMesh, pointer: pointer) == .commit {
                onCommitRequested?()
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let renderer = renderer else { return }
            if gesture.state == .changed {
                renderer.zoom(by: Float(gesture.scale))
                gesture.scale = 1
            } else if gesture.state == .ended || gesture.state == .cancelled {
                reportEditTransform()
            }
        }

        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let renderer = renderer else { return }
            if gesture.state == .changed {
                renderer.rotateZ(by: Float(gesture.rotation))
                gesture.rotation = 0
            } else if gesture.state == .ended || gesture.state == .cancelled {
                reportEditTransform()
            }
        }

        /// Reports the current model transform so the edit-session host can
        /// bake it; no-op outside edit sessions (the callback is nil).
        private func reportEditTransform() {
            guard let renderer = renderer else { return }
            onEditTransformChanged?(renderer.rotation, renderer.modelScale)
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

                let screenRadius = renderer.editPivot != nil
                    ? CGFloat(worldRadius * renderer.modelScale)
                    : CGFloat(worldRadius) * viewSize.height / CGFloat(2 * renderer.combinedRadius)
                onDeformCursor?((position: location, radius: screenRadius))
            } else if gesture.state == .ended || gesture.state == .cancelled {
                isCurrentlyDeforming = false
                onDeformCursor?(nil)
                if let activeID = renderer.activeObjectID,
                   let idx = renderer.sculptObjects.firstIndex(where: { $0.id == activeID }) {
                    let obj = renderer.sculptObjects[idx]
                    onMeshDeformed?(activeID, obj.mesh, obj.surfaceStrokes)
                    // The gesture moved vertices but hitTest still raycasts
                    // the pre-gesture BVH: ink drawn on a fresh bump lands on
                    // the OLD surface — buried inside the bump, so the stroke
                    // renders gappy on top of it. Rebuild off-main (same
                    // accepted skip-frame window as the expand-dismiss
                    // refresh; manual check 12 covers it).
                    let mesh = obj.mesh
                    Task.detached { [weak renderer] in
                        let bvh = MeshBVH(mesh: mesh)
                        await MainActor.run { renderer?.cacheBVH(bvh, for: activeID) }
                    }
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
                                                opacity: renderer.brushOpacity)
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

        private func handleCanvasDraw(_ gesture: UIPanGestureRecognizer, forceView: ForceMTKView) {
            guard let renderer = renderer else { return }
            if gesture.state == .began { canvasStrokeSamples.removeAll() }

            if gesture.state == .began || gesture.state == .changed {
                let samples = forceView.coalescedSamples
                forceView.coalescedSamples.removeAll()
                canvasStrokeSamples.append(contentsOf: samples)
                for sample in samples {
                    renderer.currentCanvasStrokePoints.append(
                        SIMD3(Float(sample.location.x), Float(-sample.location.y), 0))
                    renderer.currentCanvasStrokeWidths.append(
                        pressureWidth(force: sample.force, maxForce: sample.maxForce))
                }
            } else if gesture.state == .ended || gesture.state == .cancelled {
                forceView.coalescedSamples.removeAll()
                if canvasStrokeSamples.count > 1 {
                    let t0 = canvasStrokeSamples[0].timestamp
                    let points = canvasStrokeSamples.map { s in
                        // pressure is canonically rendered-width / widthPerPressure
                        // (StrokeConverter convention), so the committed ink width
                        // matches the live preview drawn at pressureWidth(...).
                        StrokePoint(location: s.location,
                                    pressure: CGFloat(pressureWidth(force: s.force,
                                                                    maxForce: s.maxForce))
                                        / CGFloat(StrokeLifter.widthPerPressure),
                                    tilt: .pi / 2, azimuth: 0,
                                    timestamp: s.timestamp - t0)
                    }
                    onCanvasStrokeCompleted?(Stroke(points: points))
                }
                canvasStrokeSamples.removeAll()
                renderer.currentCanvasStrokePoints.removeAll()
                renderer.currentCanvasStrokeWidths.removeAll()
            }
        }

        private func pressureWidth(force: CGFloat, maxForce: CGFloat) -> Float {
            MetalCanvasView.pressureWidth(force: force, maxForce: maxForce,
                                          brushSize: brushSize)
        }
    }
}

extension MetalCanvasView {
    /// Force → rendered ink width. UITouch documents force 1.0 as "the force
    /// of an average touch", while maximumPossibleForce is ~4.17 — real
    /// writing lives at 0.3–1.0. Normalizing by the maximum parked every
    /// stroke at the bottom of the old curve (5–25% of the brush), rendering
    /// session ink hairline and erasing light passages outright. Anchor the
    /// curve at the average touch instead: solid floor at zero force, brush
    /// width at force 1, gentle cap when pressing hard. Devices without a
    /// force stream (finger, simulator) report maxForce 0 → constant width.
    static func pressureWidth(force: CGFloat, maxForce: CGFloat,
                              brushSize: Float) -> Float {
        guard maxForce > 0 else { return brushSize }
        return brushSize * min(1.6, 0.7 + 0.3 * Float(force))
    }
}
