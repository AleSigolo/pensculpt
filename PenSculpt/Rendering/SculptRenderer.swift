import MetalKit
import simd

struct StrokeRenderUniforms {
    var mvpMatrix: simd_float4x4
}

struct MeshRenderUniforms {
    var mvpMatrix: simd_float4x4
    var lightDirection: SIMD3<Float>
    var baseColor: SIMD3<Float>
}

class SculptRenderer: NSObject, MTKViewDelegate {
    /// Compiled pipeline and depth-stencil states, cached across renderer instances
    /// to avoid re-compiling Metal shaders on every sculpt-view open.
    private struct CachedStates {
        let meshPipeline: MTLRenderPipelineState
        let surfaceStrokePipeline: MTLRenderPipelineState
        let meshDepthState: MTLDepthStencilState
        let surfaceStrokeDepthState: MTLDepthStencilState
    }
    private static var cachedStates: CachedStates?

    enum ProjectionMode {
        case orthographic
        case perspective
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let meshPipeline: MTLRenderPipelineState
    let surfaceStrokePipeline: MTLRenderPipelineState
    let meshDepthState: MTLDepthStencilState
    let surfaceStrokeDepthState: MTLDepthStencilState

    private var lastObjectIDs: Set<UUID> = []
    var sculptObjects: [SculptObject] = [] {
        didSet {
            let currentIDs = Set(sculptObjects.map(\.id))
            guard currentIDs != lastObjectIDs else { return }
            lastObjectIDs = currentIDs
            bufferCache = bufferCache.filter { currentIDs.contains($0.key) }
            bvhCache = bvhCache.filter { currentIDs.contains($0.key) }
            strokeNormalsCache.removeAll()
            prebuildBuffers()
            prebuildBVHs()
        }
    }
    var activeObjectID: UUID? {
        didSet {
            if activeObjectID != oldValue { recomputeCombinedBounds() }
        }
    }
    var config: SculptConfig = .default
    var rotation = simd_quatf(angle: -SculptConfig.default.cameraTilt, axis: SIMD3(1, 0, 0))
    var currentStrokePoints: [SIMD3<Float>] = []
    var currentStrokeWidths: [Float] = []
    var brushOpacity: Float = 1
    var lastHitT: Float = 0
    var surfaceSpaceStrokes: Bool = false
    var currentStrokeColor: CodableColor = .black

    private struct MeshBuffers {
        let vertex: MTLBuffer
        let index: MTLBuffer
        let indexCount: Int
    }
    private var bufferCache: [UUID: MeshBuffers] = [:]
    private var bvhCache: [UUID: MeshBVH] = [:]
    private var combinedCenter = SIMD3<Float>(0, 0, 0)
    private(set) var combinedRadius: Float = 1

    var projectionMode: ProjectionMode = .orthographic
    var perspectiveFOV: Float = .pi / 180 * 50  // 50° default
    /// 0 = pure ortho, 1 = pure perspective. Animated by updateProjectionTransition().
    var projectionTransition: Float = 0

    private struct MorphState {
        let objectID: UUID
        let fromVertices: [MeshVertex]
        let toVertices: [MeshVertex]
        let toMesh: Mesh
        let toStrokes: [SurfaceStroke]?
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
    }
    private var activeMorph: MorphState?

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        if let cached = Self.cachedStates {
            self.meshPipeline = cached.meshPipeline
            self.surfaceStrokePipeline = cached.surfaceStrokePipeline
            self.meshDepthState = cached.meshDepthState
            self.surfaceStrokeDepthState = cached.surfaceStrokeDepthState
            super.init()
            return
        }

        guard let library = device.makeDefaultLibrary() else { return nil }

        // Mesh pipeline (3D triangles with lighting)
        let meshDesc = MTLRenderPipelineDescriptor()
        meshDesc.vertexFunction = library.makeFunction(name: "mesh_vertex")
        meshDesc.fragmentFunction = library.makeFunction(name: "mesh_fragment")
        meshDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        meshDesc.depthAttachmentPixelFormat = .depth32Float

        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float3
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.attributes[1].format = .float3
        vertexDesc.attributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDesc.attributes[1].bufferIndex = 0
        vertexDesc.layouts[0].stride = MemoryLayout<Float>.stride * 6
        meshDesc.vertexDescriptor = vertexDesc

        // Surface stroke pipeline (3D lines on mesh)
        let surfaceStrokeDesc = MTLRenderPipelineDescriptor()
        surfaceStrokeDesc.vertexFunction = library.makeFunction(name: "surface_stroke_vertex")
        surfaceStrokeDesc.fragmentFunction = library.makeFunction(name: "stroke_fragment")
        surfaceStrokeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        surfaceStrokeDesc.colorAttachments[0].isBlendingEnabled = true
        surfaceStrokeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        surfaceStrokeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        surfaceStrokeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        surfaceStrokeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        surfaceStrokeDesc.depthAttachmentPixelFormat = .depth32Float

        // Compile both pipelines in parallel to reduce init time
        var mp: MTLRenderPipelineState?
        var ssp: MTLRenderPipelineState?
        let group = DispatchGroup()
        group.enter()
        device.makeRenderPipelineState(descriptor: meshDesc) { state, _ in mp = state; group.leave() }
        group.enter()
        device.makeRenderPipelineState(descriptor: surfaceStrokeDesc) { state, _ in ssp = state; group.leave() }
        group.wait()
        guard let mp, let ssp else { return nil }
        self.meshPipeline = mp
        self.surfaceStrokePipeline = ssp

        // Pre-create depth stencil states
        let meshDepthDesc = MTLDepthStencilDescriptor()
        meshDepthDesc.depthCompareFunction = .less
        meshDepthDesc.isDepthWriteEnabled = true

        let strokeDepthDesc = MTLDepthStencilDescriptor()
        strokeDepthDesc.depthCompareFunction = .lessEqual
        strokeDepthDesc.isDepthWriteEnabled = false

        guard let mds = device.makeDepthStencilState(descriptor: meshDepthDesc),
              let sds = device.makeDepthStencilState(descriptor: strokeDepthDesc) else { return nil }
        self.meshDepthState = mds
        self.surfaceStrokeDepthState = sds

        Self.cachedStates = CachedStates(
            meshPipeline: mp,
            surfaceStrokePipeline: ssp,
            meshDepthState: mds,
            surfaceStrokeDepthState: sds
        )

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if activeMorph != nil { updateMorph() }

        guard !sculptObjects.isEmpty,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let mvp = combinedProjection(viewSize: view.bounds.size)
        drawAllMeshes(mvp: mvp, encoder: encoder)
        drawSurfaceStrokes(mvp: mvp, encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Mesh rendering

    private func drawAllMeshes(mvp: simd_float4x4, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(meshPipeline)
        encoder.setDepthStencilState(meshDepthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        if config.displayMode == "wireframe" {
            encoder.setTriangleFillMode(.lines)
        }

        for obj in sculptObjects where !obj.mesh.isEmpty && obj.id == activeObjectID {
            guard let b = getOrCreateBuffers(for: obj), b.indexCount > 0 else { continue }

            let isActive = obj.id == activeObjectID
            var uniforms = MeshRenderUniforms(
                mvpMatrix: mvp,
                lightDirection: normalize(SIMD3<Float>(0.3, 0.6, 1.0)),
                baseColor: isActive ? SIMD3(0.85, 0.85, 0.9) : SIMD3(0.5, 0.5, 0.55)
            )

            encoder.setVertexBuffer(b.vertex, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshRenderUniforms>.size, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MeshRenderUniforms>.size, index: 2)

            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: b.indexCount,
                indexType: .uint32,
                indexBuffer: b.index,
                indexBufferOffset: 0
            )
        }
    }

    private func getOrCreateBuffers(for obj: SculptObject) -> MeshBuffers? {
        // Return cached buffers or nil; prebuildBuffers() handles async construction
        // so the render loop skips a frame instead of blocking the main thread.
        bufferCache[obj.id]
    }

    func zoom(by scale: Float) {
        combinedRadius /= scale
        combinedRadius = max(combinedRadius, 0.1)
    }

    func rotate(dx: Float, dy: Float) {
        let sensitivity: Float = 0.005
        let qx = simd_quatf(angle: -dy * sensitivity, axis: SIMD3(1, 0, 0))
        let qy = simd_quatf(angle: dx * sensitivity, axis: SIMD3(0, 1, 0))
        rotation = (qx * qy * rotation).normalized
    }

    func rotateZ(by angle: Float) {
        let qz = simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
        rotation = (qz * rotation).normalized
    }

    func combinedProjection(viewSize: CGSize) -> simd_float4x4 {
        let r = combinedRadius
        let aspect = Float(viewSize.width) / Float(viewSize.height)

        let mOrtho = Self.orthographicProjection(
            left: -r * aspect, right: r * aspect,
            bottom: -r, top: r,
            near: -r * 10, far: r * 10
        )
        let viewOrtho = simd_float4x4(rotation) * translationMatrix(-combinedCenter.x, -combinedCenter.y, -combinedCenter.z)

        // Default-path short-circuit: avoid recomputing perspective every frame
        // while in ortho mode (perspective is opt-in, so this is the hot path).
        if projectionTransition == 0 {
            return mOrtho * viewOrtho
        }

        // For perspective, position the camera at a distance that preserves the
        // framing: an object of radius r should fill the same vertical fraction
        // as in ortho. Distance d satisfies r / d = tan(fov/2), so d = r / tan(fov/2).
        let cameraDistance = r / tan(perspectiveFOV / 2)
        let mPersp = Self.perspectiveProjection(
            fovRadians: perspectiveFOV,
            aspect: aspect,
            // Camera is at d ≈ r/tan(fov/2); object spans [-r, r] around origin.
            // Set near a bit closer than the front of the object (1.2 × r margin)
            // to keep z-buffer precision tight on the visible mesh while leaving
            // room for surface strokes that sit slightly above the surface.
            near: max(cameraDistance - r * 1.2, 0.01),
            far: cameraDistance + r * 10
        )
        // Perspective view matrix needs the extra camera-distance translation
        // along -Z (camera looks down -Z), composed with rotation about origin
        // and translation of object center to origin.
        let viewPersp = translationMatrix(0, 0, -cameraDistance) * viewOrtho

        let mvpOrtho = mOrtho * viewOrtho
        let mvpPersp = mPersp * viewPersp

        // Component-wise lerp. Linear is good enough for a 0.3s tween between
        // visually similar framings (both use GL NDC z ∈ [-1, 1] after Task 1).
        let t = projectionTransition
        var result = simd_float4x4()
        for col in 0..<4 {
            result[col] = mvpOrtho[col] * (1 - t) + mvpPersp[col] * t
        }
        return result
    }

    private func recomputeCombinedBounds() {
        var minP = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxP = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)
        // Only compute bounds for the active object since we only render it
        for obj in sculptObjects where activeObjectID == nil || obj.id == activeObjectID {
            for v in obj.mesh.vertices {
                minP = min(minP, v.position)
                maxP = max(maxP, v.position)
            }
        }
        if minP.x < Float.infinity {
            combinedCenter = (minP + maxP) / 2
            let extent = maxP - minP
            combinedRadius = max(extent.x, max(extent.y, extent.z)) / 2 * 1.3
        }
    }

    #if DEBUG
    /// Test-only: directly set the combined bounds without running the bounds
    /// computation. Used by SculptRendererProjectionTests to construct a
    /// renderer with deterministic bounds.
    func setCombinedBoundsForTesting(center: SIMD3<Float>, radius: Float) {
        self.combinedCenter = center
        self.combinedRadius = radius
        self.rotation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    }
    #endif

    // MARK: - Surface stroke rendering

    private var strokeNormalsCache: [UUID: [SIMD3<Float>]] = [:]

    private func drawSurfaceStrokes(mvp: simd_float4x4, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(surfaceStrokePipeline)
        encoder.setDepthStencilState(surfaceStrokeDepthState)
        encoder.setCullMode(.none)
        encoder.setTriangleFillMode(.fill)

        var uniforms = StrokeRenderUniforms(mvpMatrix: mvp)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<StrokeRenderUniforms>.size, index: 2)

        for obj in sculptObjects where obj.id == activeObjectID {
            for stroke in obj.surfaceStrokes {
                let normals: [SIMD3<Float>]?
                if surfaceSpaceStrokes {
                    if let cached = strokeNormalsCache[stroke.id] {
                        normals = cached
                    } else {
                        let computed = nearestNormals(for: stroke.points, vertices: obj.mesh.vertices)
                        strokeNormalsCache[stroke.id] = computed
                        normals = computed
                    }
                } else {
                    normals = nil
                }
                let color = stroke.color.simd4(opacity: stroke.opacity)
                drawStrokeStrip(stroke.points, widths: stroke.widths, normals: normals, color: color, encoder: encoder)
            }
        }

        if currentStrokePoints.count > 1 {
            let widths = currentStrokeWidths.isEmpty
                ? [Float](repeating: config.surfaceStrokeWidth, count: currentStrokePoints.count)
                : currentStrokeWidths
            drawStrokeStrip(currentStrokePoints, widths: widths,
                            color: currentStrokeColor.simd4(opacity: brushOpacity * 0.6), encoder: encoder)
        }
    }

    private func nearestNormals(for points: [SIMD3<Float>], vertices: [MeshVertex]) -> [SIMD3<Float>] {
        points.map { p in
            var bestDist: Float = .infinity
            var bestNormal = SIMD3<Float>(0, 0, 1)
            for v in vertices {
                let d = simd_length_squared(v.position - p)
                if d < bestDist {
                    bestDist = d
                    bestNormal = v.normal
                }
            }
            return bestNormal
        }
    }

    private func drawStrokeStrip(_ points: [SIMD3<Float>], widths: [Float], normals: [SIMD3<Float>]? = nil,
                                  color: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        guard points.count > 1 else { return }
        var stripVerts = buildTriangleStrip(points: points, widths: widths, normals: normals)
        var colors = [SIMD4<Float>](repeating: color, count: stripVerts.count)

        guard let posBuffer = makeBuffer(&stripVerts),
              let colBuffer = makeBuffer(&colors) else { return }

        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(colBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: stripVerts.count)
    }

    private func buildTriangleStrip(points: [SIMD3<Float>], widths: [Float], normals: [SIMD3<Float>]? = nil) -> [SIMD3<Float>] {
        let viewDir = simd_act(simd_inverse(rotation), SIMD3<Float>(0, 0, -1))
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(points.count * 2)
        var lastRight = SIMD3<Float>(1, 0, 0)

        for i in 0..<points.count {
            let raw: SIMD3<Float>
            if i == 0 {
                raw = points[1] - points[0]
            } else if i == points.count - 1 {
                raw = points[i] - points[i - 1]
            } else {
                raw = points[i + 1] - points[i - 1]
            }

            // Only update perpendicular when direction is well-defined
            let dirLen = simd_length(raw)
            if dirLen > 0.001 {
                let dir = raw / dirLen
                let r = cross(dir, viewDir)
                let rLen = simd_length(r)
                if rLen > 0.001 {
                    lastRight = r / rLen
                }
            }

            var hw = (i < widths.count ? widths[i] : 3) / 2

            // Surface-space: modulate width by how much the surface faces the camera
            if surfaceSpaceStrokes, let normals, i < normals.count {
                let facing = abs(dot(normalize(normals[i]), viewDir))
                hw *= max(facing, 0.1) // clamp to 10% to avoid fully invisible strokes
            }

            vertices.append(points[i] - lastRight * hw)
            vertices.append(points[i] + lastRight * hw)
        }
        return vertices
    }

    // MARK: - Ray casting

    func hitTest(screenPoint: CGPoint, viewSize: CGSize) -> (point: SIMD3<Float>, t: Float)? {
        guard let activeID = activeObjectID,
              let obj = sculptObjects.first(where: { $0.id == activeID }),
              !obj.mesh.isEmpty else { return nil }

        let mvp = combinedProjection(viewSize: viewSize)
        let invMVP = mvp.inverse

        let ndcX = Float(2 * screenPoint.x / viewSize.width - 1)
        let ndcY = Float(1 - 2 * screenPoint.y / viewSize.height)

        // z_ndc +1 maps to the scene side (in front of camera) due to the
        // orthographic projection's z-flip. Starting the ray here makes
        // smallest t = nearest to viewer.
        let origin4 = invMVP * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let target4 = invMVP * SIMD4<Float>(ndcX, ndcY, -1, 1)
        let origin = SIMD3<Float>(origin4.x, origin4.y, origin4.z) / origin4.w
        let target = SIMD3<Float>(target4.x, target4.y, target4.z) / target4.w
        let direction = normalize(target - origin)

        guard let bvh = bvhCache[activeID] else { return nil }
        guard let result = bvh.raycast(origin: origin, direction: direction) else { return nil }
        let hitPoint = origin + result.t * direction + direction * config.surfaceStrokeOffset
        return (hitPoint, result.t)
    }

    func isTContinuous(_ newT: Float) -> Bool {
        currentStrokePoints.isEmpty || abs(newT - lastHitT) < config.surfaceStrokeMaxTJump
    }

    func cacheBVH(_ bvh: MeshBVH, for objectID: UUID) {
        bvhCache[objectID] = bvh
    }

    private func getOrCreateBVH(for objectID: UUID, mesh: Mesh) -> MeshBVH? {
        // Return cached BVH or nil; prebuildBVHs() handles async construction
        // so callers skip the current frame instead of blocking the main thread.
        bvhCache[objectID]
    }

    private func prebuildBVHs() {
        for obj in sculptObjects where !obj.mesh.isEmpty && bvhCache[obj.id] == nil {
            let id = obj.id
            let mesh = obj.mesh
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let bvh = MeshBVH(mesh: mesh)
                DispatchQueue.main.async {
                    if self?.bvhCache[id] == nil {
                        self?.bvhCache[id] = bvh
                    }
                }
            }
        }
    }

    private func prebuildBuffers() {
        let device = self.device
        for obj in sculptObjects where !obj.mesh.isEmpty && bufferCache[obj.id] == nil {
            let id = obj.id
            let mesh = obj.mesh
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var vertexData: [Float] = []
                vertexData.reserveCapacity(mesh.vertices.count * 6)
                for v in mesh.vertices {
                    vertexData.append(contentsOf: [v.position.x, v.position.y, v.position.z])
                    vertexData.append(contentsOf: [v.normal.x, v.normal.y, v.normal.z])
                }
                var indexData: [UInt32] = []
                indexData.reserveCapacity(mesh.faces.count * 3)
                for f in mesh.faces {
                    indexData.append(contentsOf: [f.indices.x, f.indices.y, f.indices.z])
                }
                guard let vb = device.makeBuffer(bytes: vertexData,
                                                  length: vertexData.count * MemoryLayout<Float>.stride,
                                                  options: .storageModeShared),
                      let ib = device.makeBuffer(bytes: indexData,
                                                  length: indexData.count * MemoryLayout<UInt32>.stride,
                                                  options: .storageModeShared) else { return }
                let buffers = MeshBuffers(vertex: vb, index: ib, indexCount: indexData.count)
                DispatchQueue.main.async {
                    if self?.bufferCache[id] == nil {
                        self?.bufferCache[id] = buffers
                    }
                }
            }
        }
    }

    func replaceMesh(objectID: UUID, mesh: Mesh, surfaceStrokes: [SurfaceStroke]? = nil) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        sculptObjects[idx].mesh = mesh
        if let surfaceStrokes { sculptObjects[idx].surfaceStrokes = surfaceStrokes }
        bvhCache.removeValue(forKey: objectID)
        strokeNormalsCache.removeAll()
        rebuildBufferSync(for: sculptObjects[idx])
    }

    func morphMesh(objectID: UUID, mesh: Mesh, surfaceStrokes: [SurfaceStroke]? = nil) {
        guard let idx = sculptObjects.firstIndex(where: { $0.id == objectID }) else { return }
        let oldVertices = sculptObjects[idx].mesh.vertices

        if oldVertices.count == mesh.vertices.count {
            activeMorph = MorphState(
                objectID: objectID,
                fromVertices: oldVertices,
                toVertices: mesh.vertices,
                toMesh: mesh,
                toStrokes: surfaceStrokes,
                startTime: CACurrentMediaTime(),
                duration: 0.3
            )
        } else {
            replaceMesh(objectID: objectID, mesh: mesh, surfaceStrokes: surfaceStrokes)
        }
    }

    private func updateMorph() {
        guard let morph = activeMorph,
              let idx = sculptObjects.firstIndex(where: { $0.id == morph.objectID }) else {
            activeMorph = nil
            return
        }

        let elapsed = CACurrentMediaTime() - morph.startTime
        let t = Float(min(elapsed / morph.duration, 1.0))
        // Smooth ease-in-out
        let smooth = t * t * (3 - 2 * t)

        var vertices = morph.fromVertices
        for i in 0..<min(vertices.count, morph.toVertices.count) {
            vertices[i].position = mix(morph.fromVertices[i].position, morph.toVertices[i].position, t: smooth)
            vertices[i].normal = normalize(mix(morph.fromVertices[i].normal, morph.toVertices[i].normal, t: smooth))
        }
        sculptObjects[idx].mesh.vertices = vertices
        rebuildBufferSync(for: sculptObjects[idx])

        if t >= 1.0 {
            sculptObjects[idx].mesh = morph.toMesh
            if let strokes = morph.toStrokes { sculptObjects[idx].surfaceStrokes = strokes }
            rebuildBufferSync(for: sculptObjects[idx])
            activeMorph = nil
        }
    }

    // MARK: - Mesh deformation

    func deformMesh(at screenPoint: CGPoint, viewSize: CGSize, strength: Float, radius: Float, screenVelocity: CGPoint) {
        guard let activeID = activeObjectID,
              let idx = sculptObjects.firstIndex(where: { $0.id == activeID }) else { return }
        let mesh = sculptObjects[idx].mesh
        guard !mesh.isEmpty else { return }

        let mvp = combinedProjection(viewSize: viewSize)
        let invMVP = mvp.inverse

        // Convert screen velocity to world-space displacement direction
        let dxNDC = Float(screenVelocity.x * 2 / viewSize.width)
        let dyNDC = Float(-screenVelocity.y * 2 / viewSize.height)
        let p0 = invMVP * SIMD4<Float>(0, 0, 0, 1)
        let p1 = invMVP * SIMD4<Float>(dxNDC, dyNDC, 0, 1)
        let p0w = SIMD3<Float>(p0.x, p0.y, p0.z) / p0.w
        let p1w = SIMD3<Float>(p1.x, p1.y, p1.z) / p1.w
        let moveDir = p1w - p0w
        let moveDirLen = simd_length(moveDir)
        guard moveDirLen > 0.001 else { return }
        let worldDir = moveDir / moveDirLen

        // Ray cast to find the deformation center
        let ndcX = Float(2 * screenPoint.x / viewSize.width - 1)
        let ndcY = Float(1 - 2 * screenPoint.y / viewSize.height)
        let origin4 = invMVP * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let target4 = invMVP * SIMD4<Float>(ndcX, ndcY, -1, 1)
        let origin = SIMD3<Float>(origin4.x, origin4.y, origin4.z) / origin4.w
        let target = SIMD3<Float>(target4.x, target4.y, target4.z) / target4.w
        let direction = normalize(target - origin)

        guard let bvh = getOrCreateBVH(for: activeID, mesh: mesh),
              let result = bvh.raycast(origin: origin, direction: direction) else { return }
        let center = origin + result.t * direction

        // Displace vertices within brush radius using Gaussian falloff
        // along the pen movement direction.
        let radiusSq = radius * radius
        var vertices = sculptObjects[idx].mesh.vertices
        var modified = false

        for i in 0..<vertices.count {
            let distSq = simd_length_squared(vertices[i].position - center)
            if distSq < radiusSq {
                let falloff = expf(-distSq / (radiusSq * 0.25))
                vertices[i].position = vertices[i].position + worldDir * strength * falloff
                modified = true
            }
        }

        if modified {
            sculptObjects[idx].mesh.vertices = vertices
            rebuildBufferSync(for: sculptObjects[idx])
        }

        // Also displace surface stroke points so they move with the mesh
        var strokes = sculptObjects[idx].surfaceStrokes
        var strokesModified = false

        for s in 0..<strokes.count {
            for p in 0..<strokes[s].points.count {
                let pos = strokes[s].points[p]
                let distSq = simd_length_squared(pos - center)
                if distSq < radiusSq {
                    let falloff = expf(-distSq / (radiusSq * 0.25))
                    strokes[s].points[p] = pos + worldDir * strength * falloff
                    strokesModified = true
                }
            }
        }

        if strokesModified {
            sculptObjects[idx].surfaceStrokes = strokes
        }
    }

    // MARK: - Stroke erasing

    func eraseNearestStroke(at point: SIMD3<Float>, objectIndex idx: Int, threshold: Float) {
        let strokes = sculptObjects[idx].surfaceStrokes
        var bestDist: Float = Float.infinity
        var bestIndex: Int?

        for (si, stroke) in strokes.enumerated() {
            for p in stroke.points {
                let dist = simd_length(p - point)
                if dist < bestDist {
                    bestDist = dist
                    bestIndex = si
                }
            }
        }

        if let si = bestIndex, bestDist < threshold {
            sculptObjects[idx].surfaceStrokes.remove(at: si)
        }
    }

    // MARK: - Laplacian smooth

    func smoothMesh(at screenPoint: CGPoint, viewSize: CGSize, strength: Float, radius: Float) {
        guard let activeID = activeObjectID,
              let idx = sculptObjects.firstIndex(where: { $0.id == activeID }) else { return }
        let mesh = sculptObjects[idx].mesh
        guard !mesh.isEmpty else { return }

        let mvp = combinedProjection(viewSize: viewSize)
        let invMVP = mvp.inverse

        let ndcX = Float(2 * screenPoint.x / viewSize.width - 1)
        let ndcY = Float(1 - 2 * screenPoint.y / viewSize.height)
        let origin4 = invMVP * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let target4 = invMVP * SIMD4<Float>(ndcX, ndcY, -1, 1)
        let origin = SIMD3<Float>(origin4.x, origin4.y, origin4.z) / origin4.w
        let target = SIMD3<Float>(target4.x, target4.y, target4.z) / target4.w
        let direction = normalize(target - origin)

        guard let bvh = getOrCreateBVH(for: activeID, mesh: mesh),
              let result = bvh.raycast(origin: origin, direction: direction) else { return }
        let center = origin + result.t * direction

        // Build adjacency: for each vertex, collect its neighbor indices
        var neighbors: [[Int]] = Array(repeating: [], count: mesh.vertices.count)
        for face in mesh.faces {
            let i0 = Int(face.indices.x), i1 = Int(face.indices.y), i2 = Int(face.indices.z)
            neighbors[i0].append(i1); neighbors[i0].append(i2)
            neighbors[i1].append(i0); neighbors[i1].append(i2)
            neighbors[i2].append(i0); neighbors[i2].append(i1)
        }

        let radiusSq = radius * radius
        var vertices = mesh.vertices
        var modified = false

        for i in 0..<vertices.count {
            let distSq = simd_length_squared(vertices[i].position - center)
            if distSq < radiusSq && !neighbors[i].isEmpty {
                let falloff = expf(-distSq / (radiusSq * 0.25))
                // Laplacian: average of neighbors
                var avg = SIMD3<Float>(0, 0, 0)
                for ni in neighbors[i] { avg += mesh.vertices[ni].position }
                avg /= Float(neighbors[i].count)
                let delta = avg - vertices[i].position
                vertices[i].position += delta * strength * falloff
                modified = true
            }
        }

        if modified {
            sculptObjects[idx].mesh.vertices = vertices
            rebuildBufferSync(for: sculptObjects[idx])
        }
    }

    /// Rebuilds the Metal buffer for an object synchronously on the main thread.
    /// Used during deformation to avoid the mesh disappearing between async rebuilds.
    private func rebuildBufferSync(for obj: SculptObject) {
        let mesh = obj.mesh
        var vertexData: [Float] = []
        vertexData.reserveCapacity(mesh.vertices.count * 6)
        for v in mesh.vertices {
            vertexData.append(contentsOf: [v.position.x, v.position.y, v.position.z])
            vertexData.append(contentsOf: [v.normal.x, v.normal.y, v.normal.z])
        }
        var indexData: [UInt32] = []
        indexData.reserveCapacity(mesh.faces.count * 3)
        for f in mesh.faces {
            indexData.append(contentsOf: [f.indices.x, f.indices.y, f.indices.z])
        }
        guard let vb = device.makeBuffer(bytes: vertexData,
                                          length: vertexData.count * MemoryLayout<Float>.stride,
                                          options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indexData,
                                          length: indexData.count * MemoryLayout<UInt32>.stride,
                                          options: .storageModeShared) else { return }
        bufferCache[obj.id] = MeshBuffers(vertex: vb, index: ib, indexCount: indexData.count)
    }

    // MARK: - Helpers

    private func makeBuffer<T>(_ data: [T]) -> MTLBuffer? {
        device.makeBuffer(bytes: data,
                          length: data.count * MemoryLayout<T>.stride,
                          options: .storageModeShared)
    }

    private func makeBuffer<T>(_ data: inout [T]) -> MTLBuffer? {
        device.makeBuffer(bytes: &data,
                          length: data.count * MemoryLayout<T>.stride,
                          options: .storageModeShared)
    }

    static func perspectiveProjection(fovRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovRadians / 2)
        let zRange = far - near
        // Vertical FOV. NDC z in [-1, 1] to match orthographicProjection's
        // convention so the two matrices can be interpolated component-wise
        // without producing non-monotonic depth during the projection-mode
        // transition animation.
        return simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2 * far * near / zRange, 0)
        ))
    }

    static func orthographicProjection(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        let sx = 2.0 / (right - left)
        let sy = 2.0 / (top - bottom)
        let sz = -2.0 / (far - near)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        let tz = -(far + near) / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, sz, 0),
            SIMD4<Float>(tx, ty, tz, 1)
        ))
    }

    private func translationMatrix(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(x, y, z, 1)
        ))
    }
}
