import SwiftUI
import MetalKit

struct SculptScreen: View {
    var strokes: [Stroke]
    @Binding var sculptObjects: [SculptObject]
    @Binding var autoProjectStrokes: Bool
    var config: SculptConfig = .default
    var activeColor: CodableColor
    var recentColors: [CodableColor]
    var onSelectPresetColor: (CodableColor) -> Void
    var onSelectCustomColor: (CodableColor) -> Void
    @State private var activeObjectID: UUID?
    @State private var isRotateMode = false
    @State private var isDeformMode = false
    @State private var isSmoothMode = false
    @State private var isEraseStrokeMode = false
    @State private var surfaceSpaceStrokes = false
    @State private var brushSize: CGFloat = 8
    @State private var brushOpacity: CGFloat = 1
    @State private var savedDrawOpacity: CGFloat = 1
    @State private var deformCursor: (position: CGPoint, radius: CGFloat)?
    @State private var rendererReplaceMesh: ((UUID, Mesh, [SurfaceStroke]?) -> Void)?
    @State private var rendererMorphMesh: ((UUID, Mesh, [SurfaceStroke]?) -> Void)?
    @State private var rendererCacheBVH: ((UUID, MeshBVH) -> Void)?
    @State private var isReInferring = false
    @State private var metalView: MTKView?
    @State private var shareURL: ShareableURL?
    @State private var exportError: ExportError?
    @State private var showFormatDialog = false
    @State private var pendingMeshFormat: MeshFormat?
    @State private var showScopeDialog = false
    @State private var showColorPopover = false
    @State private var projectionMode: SculptRenderer.ProjectionMode = .orthographic
    @State private var perspectiveFOV: Float = .pi / 180 * 50
    @State private var showFOVPopover: Bool = false
    @State private var rendererSetProjectionMode: ((SculptRenderer.ProjectionMode, Bool) -> Void)?
    @State private var rendererSetPerspectiveFOV: ((Float) -> Void)?
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
            surfaceSpaceStrokes: surfaceSpaceStrokes,
            brushSize: Float(brushSize),
            brushOpacity: Float(brushOpacity),
            activeColor: activeColor,
            onObjectTapped: cycleActiveObject,
            onSurfaceStrokeCompleted: handleSurfaceStroke,
            onMeshDeformed: handleMeshDeformed,
            onDeformCursor: { deformCursor = $0 },
            onRendererReady: { replace, morph, cacheBVH in Task { @MainActor in rendererReplaceMesh = replace; rendererMorphMesh = morph; rendererCacheBVH = cacheBVH } },
            onRendererSetProjectionMode: { setMode in Task { @MainActor in rendererSetProjectionMode = setMode } },
            onRendererSetPerspectiveFOV: { setFOV in Task { @MainActor in rendererSetPerspectiveFOV = setFOV } },
            onViewReady: { view in Task { @MainActor in metalView = view } }
        )
        .ignoresSafeArea()
        .overlay { deformCursorOverlay }
        .overlay(alignment: .topLeading) { topToolbar }
        .overlay(alignment: .top) { objectCountBadge }
        .overlay(alignment: .bottom) { bottomToolbar }
        .overlay(alignment: .bottomLeading) { rotateButton }
        .overlay(alignment: .topTrailing) { projectionControls }
        .overlay(alignment: .bottomTrailing) { sculptActionButtons }
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
        .confirmationDialog("Export", isPresented: $showFormatDialog, titleVisibility: .visible) {
            Button("Image (PNG)") { performImageExport() }
            Button("3D Mesh (OBJ)") { startMeshExport(format: .obj) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Export which?", isPresented: $showScopeDialog, titleVisibility: .visible) {
            Button("Active object") { performMeshExport(scope: .activeOnly) }
            Button("Whole scene") { performMeshExport(scope: .all) }
            Button("Cancel", role: .cancel) { pendingMeshFormat = nil }
        }
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button("OK", role: .cancel) { exportError = nil }
        } message: { err in
            Text(err.errorDescription ?? "")
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var deformCursorOverlay: some View {
        if let cursor = deformCursor {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: config.deformCursorLineWidth, dash: config.deformCursorDash))
                .foregroundStyle(.orange.opacity(config.deformCursorOpacity))
                .frame(width: cursor.radius * 2, height: cursor.radius * 2)
                .position(cursor.position)
                .allowsHitTesting(false)
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .tooltip(.sculptClose)

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
            .tooltip(.sculptReinfer)

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
            .tooltip(.sculptReinferMorph)

            Button {
                guard activeObjectIndex < sculptObjects.count, !isReInferring else { return }
                let current = sculptObjects[activeObjectIndex].inflationMode
                let newMode: InflationMode = (current == .organic) ? .straight : .organic
                sculptObjects[activeObjectIndex].inflationMode = newMode
                reInfer()
            } label: {
                let isStraight = activeObjectIndex < sculptObjects.count
                    && sculptObjects[activeObjectIndex].inflationMode == .straight
                Image(systemName: isStraight ? "cube.fill" : "circle")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isStraight ? .blue : .secondary)
            }
            .disabled(isReInferring)
            .tooltip(.sculptInflationMode)

            Button {
                autoProjectStrokes.toggle()
            } label: {
                Image(systemName: autoProjectStrokes ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(autoProjectStrokes ? .blue : .secondary)
            }
            .tooltip(.sculptAutoProject)

            Button {
                showFormatDialog = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .tooltip(.sculptExport)

            TooltipsToggleButton()
        }
        .padding()
    }

    @ViewBuilder
    private var objectCountBadge: some View {
        if sculptObjects.count > 1 {
            Text("\(activeObjectIndex + 1) / \(sculptObjects.count)")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 60)
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            Button { showColorPopover = true } label: {
                Circle()
                    .fill(Color(activeColor))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
            }
            .tooltip(.sculptColorSwatch)
            .popover(isPresented: $showColorPopover) {
                ColorPickerPopover(
                    activeColor: activeColor,
                    recentColors: recentColors,
                    onSelectPreset: onSelectPresetColor,
                    onSelectCustom: onSelectCustomColor
                )
            }

            Divider().frame(height: 24)

            BrushControls(brushSize: $brushSize, brushOpacity: $brushOpacity, isDeformMode: isDeformMode)

            Divider().frame(height: 24)

            Button {
                surfaceSpaceStrokes.toggle()
            } label: {
                Image(systemName: surfaceSpaceStrokes ? "cube.fill" : "square.fill")
                    .font(.caption)
                    .foregroundStyle(surfaceSpaceStrokes ? .blue : .secondary)
            }
            .tooltip(.sculptSurfaceSpace)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 20)
    }

    private var rotateButton: some View {
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
            .tooltip(.sculptRotate)
            .padding(20)
    }

    private var projectionControls: some View {
        HStack(spacing: 12) {
            Button {
                let newMode: SculptRenderer.ProjectionMode =
                    (projectionMode == .orthographic) ? .perspective : .orthographic
                projectionMode = newMode
                rendererSetProjectionMode?(newMode, true)
                if newMode == .orthographic {
                    showFOVPopover = false
                }
            } label: {
                Image(systemName: projectionMode == .perspective ? "view.3d" : "view.2d")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(projectionMode == .perspective ? .blue : .secondary)
            }
            .tooltip(.sculptPerspective)

            if projectionMode == .perspective {
                Button {
                    showFOVPopover.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(showFOVPopover ? .blue : .secondary)
                }
                .popover(isPresented: $showFOVPopover, arrowEdge: .top) {
                    fovPopoverContent
                }
                .tooltip(.sculptFOV)
            }
        }
        .padding()
    }

    private var fovPopoverContent: some View {
        VStack(spacing: 12) {
            Text("Field of View")
                .font(.subheadline.weight(.medium))
            HStack {
                Text("20°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(perspectiveFOV * 180 / .pi) },
                        set: { newDegrees in
                            perspectiveFOV = Float(newDegrees) * .pi / 180
                            rendererSetPerspectiveFOV?(perspectiveFOV)
                        }
                    ),
                    in: 20...90,
                    step: 1
                )
                .frame(width: 220)
                Text("90°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("\(Int(perspectiveFOV * 180 / .pi))°")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }

    private var sculptActionButtons: some View {
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
            .tooltip(.sculptEraser)

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
            .tooltip(.sculptDeform)
        }
        .padding(20)
    }

    // MARK: - Computed properties

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
        let mode = sculptObjects[idx].inflationMode
        isReInferring = true
        let sourceStrokes = strokes
        let cfg = config
        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg, inflationMode: mode)
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
        let mode = sculptObjects[activeObjectIndex].inflationMode
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg, inflationMode: mode)
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
        let mode = sculptObjects[activeObjectIndex].inflationMode
        let sourceStrokes = strokes
        let cfg = config
        isReInferring = true

        Task.detached {
            let newObj = ShapeInflater.sculpt(from: sourceStrokes, config: cfg, inflationMode: mode)
            let reprojected = oldStrokes.isEmpty ? [] : Self.reprojectStrokes(oldStrokes, onto: newObj.mesh, config: cfg)
            let bvh = MeshBVH(mesh: newObj.mesh)
            await MainActor.run {
                if let idx = sculptObjects.firstIndex(where: { $0.id == id }) {
                    sculptObjects[idx].originRect = newObj.originRect
                    sculptObjects[idx].surfaceStrokes = reprojected
                    rendererMorphMesh?(id, newObj.mesh, reprojected)
                }
                rendererCacheBVH?(id, bvh)
                // Update binding mesh after morph completes
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if let idx = sculptObjects.firstIndex(where: { $0.id == id }) {
                        sculptObjects[idx].mesh = newObj.mesh
                    }
                }
                isReInferring = false
            }
        }
    }

    private static func reprojectStrokes(_ strokes: [SurfaceStroke], onto mesh: Mesh, config: SculptConfig) -> [SurfaceStroke] {
        let rayDir = SIMD3<Float>(0, 0, -1)
        return strokes.compactMap { $0.reprojected(onto: mesh, rayDir: rayDir, offset: config.surfaceStrokeOffset, maxTJump: config.surfaceStrokeMaxTJump) }
    }

    // MARK: - Export

    private func performImageExport() {
        guard let metalView = metalView else {
            exportError = .renderFailed
            return
        }
        do {
            let url = try ImageRenderer.renderPNG(from: metalView)
            shareURL = ShareableURL(url: url)
        } catch let err as ExportError {
            exportError = err
        } catch {
            exportError = .renderFailed
        }
    }

    private func startMeshExport(format: MeshFormat) {
        pendingMeshFormat = format
        if sculptObjects.count <= 1 {
            performMeshExport(scope: .all)
        } else {
            showScopeDialog = true
        }
    }

    private func performMeshExport(scope: SculptScope) {
        guard let format = pendingMeshFormat else { return }
        defer { pendingMeshFormat = nil }

        let objectsToExport: [SculptObject]
        switch scope {
        case .activeOnly:
            if let active = sculptObjects.first(where: { $0.id == activeObjectID }) {
                objectsToExport = [active]
            } else {
                objectsToExport = []
            }
        case .all:
            objectsToExport = sculptObjects
        }

        do {
            let url = try MeshExporter.export(objectsToExport, format: format)
            shareURL = ShareableURL(url: url)
        } catch let err as ExportError {
            exportError = err
        } catch {
            exportError = .modelIOFailed(error)
        }
    }
}
