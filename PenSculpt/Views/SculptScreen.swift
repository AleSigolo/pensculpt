import SwiftUI

struct SculptScreen: View {
    var strokes: [Stroke]
    @Binding var sculptObjects: [SculptObject]
    var config: SculptConfig = .default
    @State private var activeObjectID: UUID?
    @State private var isRotateMode = false
    @State private var isDeformMode = false
    @State private var isSmoothMode = false
    @State private var isEraseStrokeMode = false
    @State private var brushSize: CGFloat = 8
    @State private var brushOpacity: CGFloat = 1
    @State private var savedDrawOpacity: CGFloat = 1
    @State private var deformCursor: (position: CGPoint, radius: CGFloat)?
    @State private var rendererReplaceMesh: ((UUID, Mesh, [SurfaceStroke]?) -> Void)?
    @State private var rendererMorphMesh: ((UUID, Mesh, [SurfaceStroke]?) -> Void)?
    @State private var rendererCacheBVH: ((UUID, MeshBVH) -> Void)?
    @State private var isReInferring = false
    /// reInferMorph's final mesh write to the binding, deferred until the
    /// renderer's cross-fade lands. Kept here so onDisappear can flush it if
    /// the workspace is dismissed inside the delay window.
    @State private var pendingMorphMeshWrite: (objectID: UUID, mesh: Mesh)?
    @State private var morphMeshWriteTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MetalCanvasView(
            sculptObjects: sculptObjects,
            activeObjectID: activeObjectID,
            config: config,
            isRotateMode: isRotateMode,
            isDeformMode: isDeformMode,
            isSmoothMode: isSmoothMode,
            isEraseStrokeMode: isEraseStrokeMode,
            brushSize: Float(brushSize),
            brushOpacity: Float(brushOpacity),
            onObjectTapped: cycleActiveObject,
            onSurfaceStrokeCompleted: handleSurfaceStroke,
            onMeshDeformed: handleMeshDeformed,
            onDeformCursor: { deformCursor = $0 },
            onRendererReady: { replace, morph, cacheBVH in Task { @MainActor in rendererReplaceMesh = replace; rendererMorphMesh = morph; rendererCacheBVH = cacheBVH } }
        )
        .ignoresSafeArea()
        .overlay {
            if let cursor = deformCursor {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: config.deformCursorLineWidth, dash: config.deformCursorDash))
                    .foregroundStyle(.orange.opacity(config.deformCursorOpacity))
                    .frame(width: cursor.radius * 2, height: cursor.radius * 2)
                    .position(cursor.position)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }

                Button(action: reInfer) {
                    if isReInferring {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isReInferring)

                Button(action: reInferMorph) {
                    if isReInferring {
                        ProgressView()
                    } else {
                        VStack(spacing: 2) {
                            Image(systemName: "sparkles")
                                .font(.title3)
                            Text("beta")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(isReInferring)
            }
            .padding()
        }
        .overlay(alignment: .top) {
            if sculptObjects.count > 1 {
                Text("\(activeObjectIndex + 1) / \(sculptObjects.count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 60)
            }
        }
        .overlay(alignment: .bottom) {
            BrushControls(brushSize: $brushSize, brushOpacity: $brushOpacity, isDeformMode: isDeformMode)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 20)
        }
        .overlay(alignment: .bottomLeading) {
            Image(systemName: isRotateMode ? "rotate.3d.fill" : "rotate.3d")
                .font(.title)
                .foregroundStyle(isRotateMode ? .blue : .secondary)
                .frame(width: 60, height: 60)
                .background(.ultraThinMaterial, in: Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isRotateMode = true }
                        .onEnded { _ in isRotateMode = false }
                )
                .padding(20)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 12) {
                Button {
                    if isDeformMode {
                        isSmoothMode.toggle()
                    } else {
                        isEraseStrokeMode.toggle()
                    }
                } label: {
                    let active = isDeformMode ? isSmoothMode : isEraseStrokeMode
                    Image(systemName: active ? "eraser.fill" : "eraser")
                        .font(.title2)
                        .foregroundStyle(active ? .mint : .secondary)
                        .frame(width: 50, height: 50)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    if isDeformMode {
                        isDeformMode = false
                        isSmoothMode = false
                        brushOpacity = savedDrawOpacity
                    } else {
                        savedDrawOpacity = brushOpacity
                        isDeformMode = true
                        isEraseStrokeMode = false
                        brushOpacity = CGFloat(config.deformDefaultForce)
                    }
                } label: {
                    Image(systemName: isDeformMode ? "hand.point.up.fill" : "hand.point.up")
                        .font(.title)
                        .foregroundStyle(isDeformMode ? .orange : .secondary)
                        .frame(width: 60, height: 60)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pencilDoubleTap)) { _ in
            if isDeformMode {
                isSmoothMode.toggle()
            } else {
                isEraseStrokeMode.toggle()
            }
        }
        .onAppear {
            let strokeIDs = Set(strokes.map(\.id))

            if let exact = sculptObjects.first(where: { $0.sourceStrokeIDs == strokeIDs }) {
                // Exact match — use existing
                activeObjectID = exact.id
            } else if let best = bestOverlappingObject(for: strokeIDs) {
                // Strokes changed — re-infer the closest matching object
                activeObjectID = best.id
                autoReInfer(objectID: best.id, newStrokeIDs: strokeIDs)
            } else {
                // No match — create new
                inferNewObject()
            }
        }
        .onDisappear {
            // Dismissed inside the morph-write delay window: flush the final
            // mesh now so the host overlay never sees the pre-morph mesh.
            morphMeshWriteTask?.cancel()
            if let pending = pendingMorphMeshWrite {
                applyMorphMeshWrite(objectID: pending.objectID, mesh: pending.mesh)
            }
        }
    }

    /// Writes reInferMorph's final mesh to the binding (idempotent — the
    /// delayed task and the onDisappear flush may not both run, but a double
    /// write would store the same mesh).
    private func applyMorphMeshWrite(objectID: UUID, mesh: Mesh) {
        pendingMorphMeshWrite = nil
        morphMeshWriteTask = nil
        if let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) {
            sculptObjects[idx].mesh = mesh
        }
    }

    private var activeObjectIndex: Int {
        sculptObjects.firstIndex(where: { $0.id == activeObjectID }) ?? 0
    }

    private func cycleActiveObject() {
        guard sculptObjects.count > 1 else { return }
        let nextIdx = (activeObjectIndex + 1) % sculptObjects.count
        activeObjectID = sculptObjects[nextIdx].id
    }

    private func handleSurfaceStroke(_ stroke: SurfaceStroke) {
        guard activeObjectIndex < sculptObjects.count else { return }
        sculptObjects[activeObjectIndex].surfaceStrokes.append(stroke)
    }

    private func handleMeshDeformed(_ objectID: UUID, _ mesh: Mesh, _ surfaceStrokes: [SurfaceStroke]) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        sculptObjects[idx].mesh = mesh
        sculptObjects[idx].surfaceStrokes = surfaceStrokes
    }

    private func bestOverlappingObject(for strokeIDs: Set<UUID>) -> SculptObject? {
        sculptObjects
            .filter { !$0.sourceStrokeIDs.intersection(strokeIDs).isEmpty }
            .max(by: { $0.sourceStrokeIDs.intersection(strokeIDs).count < $1.sourceStrokeIDs.intersection(strokeIDs).count })
    }

    private func inferNewObject() {
        isReInferring = true
        let sourceStrokes = strokes
        let cfg = config
        Task.detached {
            let obj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
            let bvh = MeshBVH(mesh: obj.mesh)
            await MainActor.run {
                sculptObjects.append(obj)
                activeObjectID = obj.id
                rendererCacheBVH?(obj.id, bvh)
                isReInferring = false
            }
        }
    }

    private func autoReInfer(objectID: UUID, newStrokeIDs: Set<UUID>) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        let oldStrokes = sculptObjects[idx].surfaceStrokes
        isReInferring = true
        let sourceStrokes = strokes
        let cfg = config
        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
            let reprojected = oldStrokes.isEmpty ? [] : Self.reprojectStrokes(oldStrokes, onto: newObj.mesh, config: cfg)
            let bvh = MeshBVH(mesh: newObj.mesh)
            await MainActor.run {
                if let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) {
                    sculptObjects[idx].mesh = newObj.mesh
                    sculptObjects[idx].sourceStrokeIDs = newStrokeIDs
                    sculptObjects[idx].originRect = newObj.originRect
                    sculptObjects[idx].surfaceStrokes = reprojected
                    rendererReplaceMesh?(objectID, newObj.mesh, reprojected)
                }
                rendererCacheBVH?(objectID, bvh)
                isReInferring = false
            }
        }
    }

    private func reInfer() {
        guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
        let id = sculptObjects[activeObjectIndex].id
        let oldStrokes = sculptObjects[activeObjectIndex].surfaceStrokes
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
            let reprojected = oldStrokes.isEmpty ? [] : Self.reprojectStrokes(oldStrokes, onto: newObj.mesh, config: cfg)
            let bvh = MeshBVH(mesh: newObj.mesh)
            await MainActor.run {
                if let idx = sculptObjects.firstIndex(where: { $0.id == id }) {
                    sculptObjects[idx].mesh = newObj.mesh
                    sculptObjects[idx].originRect = newObj.originRect
                    sculptObjects[idx].surfaceStrokes = reprojected
                    rendererReplaceMesh?(id, newObj.mesh, reprojected)
                }
                rendererCacheBVH?(id, bvh)
                isReInferring = false
            }
        }
    }

    private func reInferMorph() {
        guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
        let id = sculptObjects[activeObjectIndex].id
        let oldStrokes = sculptObjects[activeObjectIndex].surfaceStrokes
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg)
            let reprojected = oldStrokes.isEmpty ? [] : Self.reprojectStrokes(oldStrokes, onto: newObj.mesh, config: cfg)
            let bvh = MeshBVH(mesh: newObj.mesh)
            await MainActor.run {
                if let idx = sculptObjects.firstIndex(where: { $0.id == id }) {
                    sculptObjects[idx].originRect = newObj.originRect
                    sculptObjects[idx].surfaceStrokes = reprojected
                    rendererMorphMesh?(id, newObj.mesh, reprojected)
                }
                rendererCacheBVH?(id, bvh)
                // Update the binding mesh only after the renderer's morph
                // animation completes. Tracked as a pending write so that
                // dismissing the workspace inside the window flushes it
                // (onDisappear) instead of leaving the binding — and any
                // overlay caches rebuilt from it — holding the pre-morph mesh.
                pendingMorphMeshWrite = (id, newObj.mesh)
                morphMeshWriteTask = Task { [mesh = newObj.mesh] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    applyMorphMeshWrite(objectID: id, mesh: mesh)
                }
                isReInferring = false
            }
        }
    }

    private static func reprojectStrokes(_ strokes: [SurfaceStroke], onto mesh: Mesh, config: SculptConfig) -> [SurfaceStroke] {
        let rayDir = SIMD3<Float>(0, 0, -1)
        return strokes.compactMap { $0.reprojected(onto: mesh, rayDir: rayDir, offset: config.surfaceStrokeOffset, maxTJump: config.surfaceStrokeMaxTJump) }
    }
}
