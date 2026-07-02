import XCTest
import Metal
import simd
@testable import PenSculpt

/// Empirical GPU ground-truth tests for the rendering convention set:
/// projection z-mapping, clipping, cull/winding, depth ordering, and the
/// surface-stroke depth offset. These render offscreen through the SAME
/// shader functions, vertex layout, depth states, and cull configuration
/// as SculptRenderer, using CameraTransform's real matrices, and read the
/// pixels back.
///
/// Ground truth measured 2026-07-02 with the ORIGINAL (OpenGL-convention)
/// ortho matrix, which mapped z to NDC [−1, +1] while Metal clips to [0, 1]:
///   (a) ALL world/view z > 0 geometry was clipped (0 covered pixels at
///       z = +10/+100/+1000; z < 0 rendered fine) — half of every inflated
///       mesh was silently discarded.
///   (b) With .back/.counterClockwise, ShapeInflater's viewer-facing sheet
///       (winding normal −z, shading normal +z) was CULLED, and the pillow's
///       z=−d back sheet rendered (ambient-only ~0.4 gray: its shading
///       normal faces away from the light).
///   (c) A stroke offset +z of the surface rendered on top (.lessEqual);
///       −z was hidden.
///   (d) A quad rotated 45° about y lost the half that crossed into z > 0
///       (2240 of an expected ~4480 covered pixels).
/// The tests below pin the CORRECTED convention: Metal [0, 1] depth mapping
/// with the viewer at +z (larger world z = nearer), full ±depthRange slab
/// visible, front-facing = .clockwise so the viewer-facing sheet survives.
final class MetalConventionTests: XCTestCase {

    // MARK: - Harness

    private final class Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let meshPipeline: MTLRenderPipelineState
        let strokePipeline: MTLRenderPipelineState
        let meshDepthState: MTLDepthStencilState
        let strokeDepthState: MTLDepthStencilState
        let width = 100
        let height = 100

        struct MeshDraw {
            var vertices: [MeshVertex]
            var faces: [MeshFace]
            var baseColor: SIMD3<Float> = SIMD3(1, 1, 1)
        }

        struct StrokeDraw {
            /// Triangle-strip vertices (pre-built band), like drawStrokeStrip's output.
            var strip: [SIMD3<Float>]
            var color: SIMD4<Float>
        }

        struct SetupError: Error, CustomStringConvertible {
            let reason: String
            var description: String { reason }
        }

        init(device: MTLDevice) throws {
            guard let queue = device.makeCommandQueue() else {
                throw SetupError(reason: "makeCommandQueue() returned nil")
            }
            guard let library = device.makeDefaultLibrary() else {
                throw SetupError(reason: "makeDefaultLibrary() returned nil (shader library missing from test host)")
            }
            self.device = device
            self.queue = queue

            // Mesh pipeline — mirror of SculptRenderer.init
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

            let strokeDesc = MTLRenderPipelineDescriptor()
            strokeDesc.vertexFunction = library.makeFunction(name: "surface_stroke_vertex")
            strokeDesc.fragmentFunction = library.makeFunction(name: "stroke_fragment")
            strokeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            strokeDesc.colorAttachments[0].isBlendingEnabled = true
            strokeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            strokeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            strokeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            strokeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            strokeDesc.depthAttachmentPixelFormat = .depth32Float

            let meshDepthDesc = MTLDepthStencilDescriptor()
            meshDepthDesc.depthCompareFunction = .less
            meshDepthDesc.isDepthWriteEnabled = true
            let strokeDepthDesc = MTLDepthStencilDescriptor()
            strokeDepthDesc.depthCompareFunction = .lessEqual
            strokeDepthDesc.isDepthWriteEnabled = false

            do {
                meshPipeline = try device.makeRenderPipelineState(descriptor: meshDesc)
            } catch {
                throw SetupError(reason: "mesh pipeline compilation failed: \(error)")
            }
            do {
                strokePipeline = try device.makeRenderPipelineState(descriptor: strokeDesc)
            } catch {
                throw SetupError(reason: "stroke pipeline compilation failed: \(error)")
            }
            guard let mds = device.makeDepthStencilState(descriptor: meshDepthDesc) else {
                throw SetupError(reason: "mesh depth-stencil state creation failed")
            }
            guard let sds = device.makeDepthStencilState(descriptor: strokeDepthDesc) else {
                throw SetupError(reason: "stroke depth-stencil state creation failed")
            }
            meshDepthState = mds
            strokeDepthState = sds
        }

        /// Renders meshes then strokes (same order as SculptRenderer.draw) and
        /// returns BGRA pixels. Defaults mirror SculptRenderer's mesh pass:
        /// cull .back with front-facing .clockwise.
        func render(mvp: simd_float4x4, meshes: [MeshDraw],
                    cullMode: MTLCullMode = .back,
                    winding: MTLWinding = .clockwise,
                    strokes: [StrokeDraw] = []) -> [UInt8]? {
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            texDesc.usage = [.renderTarget]
            texDesc.storageMode = .private
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depthDesc.usage = [.renderTarget]
            depthDesc.storageMode = .private
            guard let colorTex = device.makeTexture(descriptor: texDesc),
                  let depthTex = device.makeTexture(descriptor: depthDesc) else { return nil }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colorTex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depthTex
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1.0
            pass.depthAttachment.storeAction = .dontCare

            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }

            enc.setRenderPipelineState(meshPipeline)
            enc.setDepthStencilState(meshDepthState)
            enc.setCullMode(cullMode)
            enc.setFrontFacing(winding)

            for mesh in meshes {
                var vertexData: [Float] = []
                for v in mesh.vertices {
                    vertexData.append(contentsOf: [v.position.x, v.position.y, v.position.z])
                    vertexData.append(contentsOf: [v.normal.x, v.normal.y, v.normal.z])
                }
                var indexData: [UInt32] = []
                for f in mesh.faces {
                    indexData.append(contentsOf: [f.indices.x, f.indices.y, f.indices.z])
                }
                guard let vb = device.makeBuffer(bytes: vertexData,
                                                 length: vertexData.count * MemoryLayout<Float>.stride),
                      let ib = device.makeBuffer(bytes: indexData,
                                                 length: indexData.count * MemoryLayout<UInt32>.stride)
                else { return nil }
                var uniforms = MeshRenderUniforms(
                    mvpMatrix: mvp,
                    lightDirection: normalize(SIMD3<Float>(0.3, 0.6, 1.0)),
                    baseColor: mesh.baseColor)
                enc.setVertexBuffer(vb, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<MeshRenderUniforms>.size, index: 2)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<MeshRenderUniforms>.size, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: indexData.count,
                                          indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            }

            if !strokes.isEmpty {
                enc.setRenderPipelineState(strokePipeline)
                enc.setDepthStencilState(strokeDepthState)
                enc.setCullMode(.none)
                var uniforms = StrokeRenderUniforms(mvpMatrix: mvp)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<StrokeRenderUniforms>.size, index: 2)
                for stroke in strokes {
                    var verts = stroke.strip
                    var colors = [SIMD4<Float>](repeating: stroke.color, count: verts.count)
                    guard let pb = device.makeBuffer(bytes: &verts,
                                                     length: verts.count * MemoryLayout<SIMD3<Float>>.stride),
                          let cb = device.makeBuffer(bytes: &colors,
                                                     length: colors.count * MemoryLayout<SIMD4<Float>>.stride)
                    else { return nil }
                    enc.setVertexBuffer(pb, offset: 0, index: 0)
                    enc.setVertexBuffer(cb, offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: verts.count)
                }
            }

            enc.endEncoding()

            let bytesPerRow = width * 4
            guard let readback = device.makeBuffer(length: bytesPerRow * height,
                                                   options: .storageModeShared),
                  let blit = cmd.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: colorTex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: readback, destinationOffset: 0,
                      destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * height)
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            guard cmd.status == .completed else { return nil }

            let ptr = readback.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            return Array(UnsafeBufferPointer(start: ptr, count: bytesPerRow * height))
        }
    }

    private enum HarnessState {
        case ready(Harness)
        case noMetalDevice
        case setupFailed(String)
    }

    private static let harnessState: HarnessState = {
        guard let device = MTLCreateSystemDefaultDevice() else { return .noMetalDevice }
        do {
            return .ready(try Harness(device: device))
        } catch {
            return .setupFailed(String(describing: error))
        }
    }()

    /// These convention pins are load-bearing: a silently skipped suite would
    /// vacate them. Any setup problem on a machine that HAS a Metal device is
    /// therefore a test FAILURE, not a skip. The only allowed skip is when
    /// MTLCreateSystemDefaultDevice() itself returns nil — i.e. a genuinely
    /// Metal-less environment (e.g. a bare CI container with no GPU stack).
    /// The iOS simulator provides Metal, so on any supported dev machine the
    /// suite runs.
    private func requireHarness() throws -> Harness {
        switch Self.harnessState {
        case .ready(let harness):
            return harness
        case .noMetalDevice:
            throw XCTSkip("No Metal device in this environment (MTLCreateSystemDefaultDevice() == nil)")
        case .setupFailed(let reason):
            XCTFail("Metal convention harness setup failed: \(reason)")
            throw Harness.SetupError(reason: reason)
        }
    }

    /// Pixel at screen (x, y) as (b, g, r, a).
    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int, width: Int = 100) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    private func coveredPixelCount(_ pixels: [UInt8]) -> Int {
        var n = 0
        var i = 3
        while i < pixels.count { if pixels[i] > 0 { n += 1 }; i += 4 }
        return n
    }

    // MARK: - Fixtures

    private let identity = simd_quatf(vector: SIMD4(0, 0, 0, 1))

    private func makeCam(orientation: simd_quatf? = nil) -> CameraTransform {
        CameraTransform(viewSize: CGSize(width: 100, height: 100),
                        center: SIMD3(50, -50, 0),
                        orientation: orientation ?? identity, scale: 1)
    }

    /// Full-ish view quad at a given z, canvas rect (10,10)-(90,90), both windings
    /// so it renders regardless of cull mode.
    private func quad(z: Float, doubleSided: Bool) -> Harness.MeshDraw {
        let n = SIMD3<Float>(0, 0, 1)
        let vertices = [
            MeshVertex(position: SIMD3(10, -10, z), normal: n),   // tl
            MeshVertex(position: SIMD3(90, -10, z), normal: n),   // tr
            MeshVertex(position: SIMD3(10, -90, z), normal: n),   // bl
            MeshVertex(position: SIMD3(90, -90, z), normal: n),   // br
        ]
        var faces = [
            MeshFace(indices: SIMD3(0, 1, 2)), MeshFace(indices: SIMD3(1, 3, 2)),
        ]
        if doubleSided {
            faces += [MeshFace(indices: SIMD3(0, 2, 1)), MeshFace(indices: SIMD3(1, 2, 3))]
        }
        return Harness.MeshDraw(vertices: vertices, faces: faces)
    }

    /// ShapeInflater-style mini pillow: front sheet at z=+d with the exact front
    /// winding (tl,tr,bl)/(tr,br,bl) and shading normal +z; back sheet at z=−d
    /// with back winding (tl,bl,tr)/(tr,bl,br) and shading normal −z.
    /// tl/tr/bl/br refer to CANVAS orientation (row grows down, world y = −canvas y),
    /// exactly like ShapeInflater.buildMesh.
    private func pillow(d: Float) -> Harness.MeshDraw {
        let vertices = [
            // Front sheet (z = +d), shading normals +z
            MeshVertex(position: SIMD3(10, -10, d), normal: SIMD3(0, 0, 1)),   // 0 tl
            MeshVertex(position: SIMD3(90, -10, d), normal: SIMD3(0, 0, 1)),   // 1 tr
            MeshVertex(position: SIMD3(10, -90, d), normal: SIMD3(0, 0, 1)),   // 2 bl
            MeshVertex(position: SIMD3(90, -90, d), normal: SIMD3(0, 0, 1)),   // 3 br
            // Back sheet (z = −d), shading normals −z
            MeshVertex(position: SIMD3(10, -10, -d), normal: SIMD3(0, 0, -1)), // 4 tlB
            MeshVertex(position: SIMD3(90, -10, -d), normal: SIMD3(0, 0, -1)), // 5 trB
            MeshVertex(position: SIMD3(10, -90, -d), normal: SIMD3(0, 0, -1)), // 6 blB
            MeshVertex(position: SIMD3(90, -90, -d), normal: SIMD3(0, 0, -1)), // 7 brB
        ]
        let faces = [
            // ShapeInflater front: (tl, tr, bl), (tr, br, bl) → geometric winding normal −z
            MeshFace(indices: SIMD3(0, 1, 2)), MeshFace(indices: SIMD3(1, 3, 2)),
            // ShapeInflater back: (tlB, blB, trB), (trB, blB, brB) → geometric winding normal +z
            MeshFace(indices: SIMD3(4, 6, 5)), MeshFace(indices: SIMD3(5, 6, 7)),
        ]
        return Harness.MeshDraw(vertices: vertices, faces: faces)
    }

    /// Horizontal band across the view at world y=−50, at the given z.
    private func strokeBand(z: Float, color: SIMD4<Float>) -> Harness.StrokeDraw {
        Harness.StrokeDraw(strip: [
            SIMD3(10, -46, z), SIMD3(10, -54, z),
            SIMD3(90, -46, z), SIMD3(90, -54, z),
        ], color: color)
    }

    // MARK: - Regression tests (corrected convention)

    /// (a) Nothing in the ±depthRange slab is clipped: geometry at world
    /// z > 0 AND z < 0 renders. Under the old GL-convention matrix every
    /// z > 0 quad here rendered zero pixels.
    func testFullDepthRangeRendersWithoutClipping() throws {
        let h = try requireHarness()
        let mvp = makeCam().mvpMatrix
        for z in [Float(10), -10, 1000, -1000] {
            let px = try XCTUnwrap(h.render(mvp: mvp, meshes: [quad(z: z, doubleSided: true)],
                                            cullMode: .none))
            XCTAssertEqual(coveredPixelCount(px), 6400,
                           "80x80 quad at z=\(z) must be fully visible (not clipped)")
        }
    }

    /// (b) With the production cull config (.back/.clockwise), the pillow
    /// sheet that colors the pixels is the VIEWER-FACING one: z = +d with
    /// shading normal +z, so it is lit (bright), not ambient-only.
    func testViewerFacingSheetSurvivesCullAndDepth() throws {
        let h = try requireHarness()
        let mvp = makeCam().mvpMatrix

        let px = try XCTUnwrap(h.render(mvp: mvp, meshes: [pillow(d: 5)]))
        let c = pixel(px, 50, 50)
        XCTAssertEqual(coveredPixelCount(px), 6400, "Pillow must be visible")
        // Front sheet (shading normal +z): ~0.4 + 0.6*dot(+z, light) ≈ 0.90 → ~229.
        // Back sheet (shading normal −z) would be ambient-only 0.4 → ~102.
        XCTAssertGreaterThan(c.r, 200,
            "Center pixel must come from the lit viewer-facing sheet (z=+d, normal +z), got r=\(c.r)")

        // The viewer-facing winding alone survives the cull...
        let front = Harness.MeshDraw(vertices: pillow(d: 5).vertices,
                                     faces: [MeshFace(indices: SIMD3(0, 1, 2)),
                                             MeshFace(indices: SIMD3(1, 3, 2))])
        let pxFront = try XCTUnwrap(h.render(mvp: mvp, meshes: [front]))
        XCTAssertEqual(coveredPixelCount(pxFront), 6400,
                       "ShapeInflater front winding (geometric normal −z) must pass the cull")
        // ...and the away-facing winding is culled.
        let back = Harness.MeshDraw(vertices: pillow(d: 5).vertices,
                                    faces: [MeshFace(indices: SIMD3(4, 6, 5)),
                                            MeshFace(indices: SIMD3(5, 6, 7))])
        let pxBack = try XCTUnwrap(h.render(mvp: mvp, meshes: [back]))
        XCTAssertEqual(coveredPixelCount(pxBack), 0,
                       "ShapeInflater back winding (geometric normal +z) must be culled")
    }

    /// (c) A stroke offset toward the viewer (+z of the surface, what hitTest
    /// and castOntoMesh now produce) renders on top of the mesh under the
    /// .lessEqual no-write stroke depth state; an offset behind is hidden.
    func testSurfaceStrokeOffsetRendersOnTopOfMesh() throws {
        let h = try requireHarness()
        let mvp = makeCam().mvpMatrix
        let mesh = quad(z: 5, doubleSided: true)
        let red = SIMD4<Float>(1, 0, 0, 1)

        let onTop = try XCTUnwrap(h.render(mvp: mvp, meshes: [mesh], cullMode: .none,
                                           strokes: [strokeBand(z: 5.5, color: red)]))
        let cTop = pixel(onTop, 50, 50)
        XCTAssertEqual(cTop.r, 255, "Stroke offset toward viewer must render on top of the mesh")
        XCTAssertEqual(cTop.g, 0, "Stroke pixel must be pure red (not mesh gray)")

        let behind = try XCTUnwrap(h.render(mvp: mvp, meshes: [mesh], cullMode: .none,
                                            strokes: [strokeBand(z: 4.5, color: red)]))
        let cBehind = pixel(behind, 50, 50)
        XCTAssertEqual(cBehind.g, cBehind.r,
                       "Stroke offset behind the surface must be depth-rejected (mesh gray, not red)")
    }

    /// Companion to the pillow pin above: the pillow is a HAND-TRANSCRIBED
    /// replica of ShapeInflater's winding, so it could silently drift from the
    /// real thing. This renders ACTUAL ShapeInflater.inflate output (a circle
    /// of ink → inflated dome) through the production pipeline/camera and
    /// asserts the viewer-facing sheet renders lit — pinning the inflater's
    /// winding itself, not a transcription of it.
    func testRealShapeInflaterOutputRendersLit() throws {
        let h = try requireHarness()

        // Closed circle in canvas coordinates, centered in the 100x100 view.
        let points = (0...64).map { i -> StrokePoint in
            let angle = CGFloat(i) / 64 * 2 * .pi
            return StrokePoint(location: CGPoint(x: 50 + 35 * cos(angle),
                                                 y: 50 + 35 * sin(angle)),
                               pressure: 1, tilt: 0, azimuth: 0,
                               timestamp: TimeInterval(i) * 0.01)
        }
        let mesh = ShapeInflater.inflate(strokes: [Stroke(points: points)])
        XCTAssertFalse(mesh.isEmpty, "ShapeInflater must inflate a closed circle")

        // Standard edit camera and the production cull config (.back/.clockwise).
        let px = try XCTUnwrap(h.render(
            mvp: makeCam().mvpMatrix,
            meshes: [Harness.MeshDraw(vertices: mesh.vertices, faces: mesh.faces)]))

        // The inflated disk (radius ~35 → ~3800 px) must survive the cull...
        XCTAssertGreaterThan(coveredPixelCount(px), 2500,
                             "Inflated mesh must render with non-trivial coverage")
        // ...and the pixels must come from the LIT viewer-facing sheet
        // (shading normal ≈ +z → ~0.9 → ~229). If the winding regressed, the
        // ambient-only back sheet (~0.4 → ~102) would render instead.
        let center = pixel(px, 50, 50)
        XCTAssertGreaterThan(center.r, 200,
            "Dome center must come from the lit viewer-facing sheet, got r=\(center.r)")
        var litCount = 0
        for y in 0..<h.height {
            for x in 0..<h.width {
                let c = pixel(px, x, y)
                if c.a > 0 && c.r > 200 { litCount += 1 }
            }
        }
        XCTAssertGreaterThan(litCount, 500,
            "Viewer-facing sheet must render a non-trivial lit region, got \(litCount) lit px")
    }

    /// Legacy sculpt camera (combinedProjection: object-fit ortho * default
    /// −0.8 x-tilt view) still renders the pillow after the depth-mapping fix.
    func testLegacyCombinedCameraStillRendersPillow() throws {
        let h = try requireHarness()
        // Replicate SculptRenderer.combinedProjection for the pillow fixture:
        // center (50,−50,0), extent 80 → radius 52, square view.
        let r: Float = 52
        let proj = SculptRenderer.orthographicProjection(
            left: -r, right: r, bottom: -r, top: r, near: -r * 10, far: r * 10)
        let rotation = simd_quatf(angle: -SculptConfig.default.cameraTilt, axis: SIMD3(1, 0, 0))
        let view = simd_float4x4(rotation)
            * CameraTransform.translation(SIMD3(-50, 50, 0))
        let px = try XCTUnwrap(h.render(mvp: proj * view, meshes: [pillow(d: 5)]))
        XCTAssertGreaterThan(coveredPixelCount(px), 3000,
                             "Legacy tilted sculpt camera must still render the mesh")
        XCTAssertEqual(pixel(px, 50, 50).a, 255, "Pillow center must be covered")
    }

    /// (d) The headline 2.5D bug: rotating a shape must not slice it at the
    /// canvas plane. Under the old matrix the half rotated into z > 0
    /// disappeared (2240 covered pixels instead of ~4480).
    func testRotated45DegreesRendersBothHalves() throws {
        let h = try requireHarness()
        let rotCam = makeCam(orientation: simd_quatf(angle: .pi / 4, axis: SIMD3(0, 1, 0)))
        let px = try XCTUnwrap(h.render(mvp: rotCam.mvpMatrix,
                                        meshes: [quad(z: 0, doubleSided: true)],
                                        cullMode: .none))
        XCTAssertGreaterThan(pixel(px, 30, 50).a, 0, "Half rotated toward viewer must be visible")
        XCTAssertGreaterThan(pixel(px, 70, 50).a, 0, "Half rotated away from viewer must be visible")
        XCTAssertGreaterThan(coveredPixelCount(px), 4000,
                             "Both halves of the rotated quad must survive (was ~2240 when clipped)")
    }
}
