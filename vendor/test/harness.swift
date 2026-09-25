import Foundation
import Metal

func msg(_ e: libra_error_t?) -> String {
    guard let e else { return "ok" }
    var out: UnsafeMutablePointer<CChar>? = nil
    _ = libra_error_write(e, &out)
    let s = out != nil ? String(cString: out!) : "unknown"
    _ = libra_error_free_string(&out)
    var h: libra_error_t? = e; _ = libra_error_free(&h)
    return s
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSString(string: "~/Chicago95/shaders/newpixie-flat/newpixie-flat.slangp").expandingTildeInPath
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
print("device", device.name, "queue ok")

var preset: libra_shader_preset_t? = nil
print("preset_create:", msg(libra_preset_create(path, &preset)))
var list = libra_preset_param_list_t()
print("get_runtime_params:", msg(libra_preset_get_runtime_params(&preset, &list)), "count", list.length)
for i in 0..<Int(list.length) { let p = list.parameters[i]; print("  param", String(cString: p.name), p.initial, p.minimum, p.maximum, p.step) }
_ = libra_preset_free_runtime_params(list)

var opts = filter_chain_mtl_opt_t(); opts.version = LIBRASHADER_API_VERSION(LIBRASHADER_CURRENT_VERSION); opts.force_no_mipmaps = false
var chain: libra_mtl_filter_chain_t? = nil
print("chain_create:", msg(libra_mtl_filter_chain_create(&preset, queue, &opts, &chain)))
guard chain != nil else { exit(1) }
print("set curvature:", msg(libra_mtl_filter_chain_set_param(&chain, "curvature", 0.0001)))

func tex(_ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = usage; return device.makeTexture(descriptor: d)!
}
let input = tex(1280, 960, [.shaderRead, .shaderWrite, .renderTarget])
let output = tex(2560, 1920, [.shaderRead, .shaderWrite, .renderTarget])
for frame in 0..<3 {
    let cmd = queue.makeCommandBuffer()!
    var vp = libra_viewport_t(x: 0, y: 0, width: 2560, height: 1920)
    var fo = frame_mtl_opt_t(); fo.version = LIBRASHADER_API_VERSION(LIBRASHADER_CURRENT_VERSION); fo.frame_direction = 1; fo.total_subframes = 1; fo.current_subframe = 1; fo.frames_per_second = 60; fo.frametime_delta = 16; fo.brightness_nits = 200
    let r = libra_mtl_filter_chain_frame(&chain, cmd, frame, input, output, &vp, nil, &fo)
    print("frame \(frame):", msg(r))
    cmd.commit(); cmd.waitUntilCompleted()
    print("  cmd status", cmd.status.rawValue, cmd.error.map { "\($0)" } ?? "")
}
_ = libra_mtl_filter_chain_free(&chain)
print("done")
