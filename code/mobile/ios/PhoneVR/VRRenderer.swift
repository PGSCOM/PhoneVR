import Metal
import MetalKit
import CoreVideo
import simd

/// Renders a stereoscopic VR frame with barrel distortion using Metal.
/// Each eye occupies one half of the screen (left | right).
/// The distortion pipeline:
///   decoded CVPixelBuffer → CVMetalTexture → full-width sampled texture
///   per-eye render pass: sample [0,0.5) or [0.5,1) of the texture
///                        + apply barrel distortion fragment shader
final class VRRenderer: NSObject {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var videoTexture: MTLTexture?
    private var vertexBuffer: MTLBuffer?

    // Distortion coefficients for a generic Cardboard-style viewer.
    // k1, k2 matching the polynomial: r' = r*(1 + k1*r² + k2*r⁴)
    private var distortionK1: Float = 0.34
    private var distortionK2: Float = 0.55

    init?(mtkView: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue
        super.init()

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)

        setupTextureCache()
        setupPipeline(mtkView: mtkView)
        setupVertexBuffer()
    }

    // MARK: - Texture update from VideoToolbox

    func updateVideoTexture(_ pixelBuffer: CVPixelBuffer) {
        var cvTexture: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let cache = textureCache else { return }

        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            w, h, 0,
            &cvTexture)

        if status == kCVReturnSuccess, let cvTexture {
            videoTexture = CVMetalTextureGetTexture(cvTexture)
        }
    }

    // MARK: - Render

    func render(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let pipeline = pipelineState,
              let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var params = DistortionParams(k1: distortionK1, k2: distortionK2)

        encoder.setFragmentTexture(videoTexture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<DistortionParams>.stride, index: 0)

        // Left eye: output NDC x ∈ [-1, 0],  sample UV x ∈ [0, 0.5)
        // Formula: out.x = v.x * screenScaleX + screenOffsetX
        //          Left:  v.x*0.5 + (-0.5) → [-1, 0] ✓
        var leftUniforms = EyeUniforms(uvOffsetX: 0.0, uvScaleX: 0.5,
                                        screenOffsetX: -0.5, screenScaleX: 0.5)
        encoder.setVertexBytes(&leftUniforms, length: MemoryLayout<EyeUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Right eye: output NDC x ∈ [0, 1],  sample UV x ∈ [0.5, 1)
        //          Right: v.x*0.5 + 0.5     → [0, 1]  ✓
        var rightUniforms = EyeUniforms(uvOffsetX: 0.5, uvScaleX: 0.5,
                                         screenOffsetX: 0.5, screenScaleX: 0.5)
        encoder.setVertexBytes(&rightUniforms, length: MemoryLayout<EyeUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - Setup

    private func setupTextureCache() {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    private func setupPipeline(mtkView: MTKView) {
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
            // Compile shaders from source if default library is unavailable.
            guard let lib = try? device.makeLibrary(source: metalShaderSource, options: nil) else { return }
            buildPipeline(library: lib, pixelFormat: mtkView.colorPixelFormat)
            return
        }
        buildPipeline(library: library, pixelFormat: mtkView.colorPixelFormat)
    }

    private func buildPipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vr_vertex")
        desc.fragmentFunction = library.makeFunction(name: "vr_fragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func setupVertexBuffer() {
        // Full-screen quad as two triangles (triangle strip).
        // Positions in NDC; UVs will be computed per-eye in the vertex shader.
        let verts: [Float] = [
            -1, -1,   0, 1,   // bottom-left
             1, -1,   1, 1,   // bottom-right
            -1,  1,   0, 0,   // top-left
             1,  1,   1, 0,   // top-right
        ]
        vertexBuffer = device.makeBuffer(bytes: verts,
                                         length: verts.count * MemoryLayout<Float>.stride,
                                         options: .storageModeShared)
    }

    func setDistortionCoefficients(k1: Float, k2: Float) {
        distortionK1 = k1
        distortionK2 = k2
    }
}

// MARK: - GPU types

private struct DistortionParams {
    var k1: Float
    var k2: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

private struct EyeUniforms {
    var uvOffsetX: Float
    var uvScaleX: Float
    var screenOffsetX: Float
    var screenScaleX: Float
}

// MARK: - Inline Metal shader source (fallback when not compiled in .metal file)

private let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
};

struct EyeUniforms {
    float uvOffsetX;
    float uvScaleX;
    float screenOffsetX;
    float screenScaleX;
};

struct DistortionParams {
    float k1;
    float k2;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vr_vertex(uint vid [[vertex_id]],
                            const device float4* verts [[buffer(0)]],
                            constant EyeUniforms& eye  [[buffer(1)]]) {
    float4 v = verts[vid];
    VertexOut out;
    // v.xy = NDC [-1,1] input position; map to half-screen:
    //   out.x = v.x * screenScaleX + screenOffsetX
    out.position = float4(v.x * eye.screenScaleX + eye.screenOffsetX, v.y, 0.0, 1.0);
    out.uv = float2(eye.uvOffsetX + v.z * eye.uvScaleX, v.w);
    return out;
}

fragment float4 vr_fragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             constant DistortionParams& d [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Barrel distortion: undistort screen coords before sampling.
    float2 center = float2(0.5, 0.5);
    float2 p = in.uv - center;
    float r2 = dot(p, p);
    float distort = 1.0 + d.k1 * r2 + d.k2 * r2 * r2;
    float2 distorted = p / distort + center;
    if (distorted.x < 0.0 || distorted.x > 1.0 ||
        distorted.y < 0.0 || distorted.y > 1.0) {
        return float4(0, 0, 0, 1);
    }
    return tex.sample(s, distorted);
}
"""
