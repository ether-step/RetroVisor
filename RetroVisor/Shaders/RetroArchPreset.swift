// -----------------------------------------------------------------------------
// This file is part of RetroVisor (chicago95 fork)
//
// RetroArchPreset: a RetroArch shader preset (.slangp) run live through
// librashader's Metal runtime, so the effect window shows the same shader
// the posting still is rendered with.
//
// The preset path and the parameter overrides come from the app's defaults:
//
//   defaults write de.dirkwhoffmann.de.RetroVisor RetroArchPreset \
//       ~/Chicago95/shaders/newpixie-flat/newpixie-flat.slangp
//   defaults write de.dirkwhoffmann.de.RetroVisor RetroArchPresetParams \
//       "curvature=0.0001,vignette=0,use_frame=0"
//
// Both have those values as their built-in defaults. The preset's own
// parameters appear in Settings > Shader like any other shader's.
//
// Licensed under the GNU General Public License v3, as RetroVisor is.
// -----------------------------------------------------------------------------

import MetalKit
import MetalPerformanceShaders

@MainActor
final class RetroArchPreset: Shader {

    static let pathKey = "RetroArchPreset"
    static let paramsKey = "RetroArchPresetParams"
    static let defaultPath = "~/Chicago95/shaders/newpixie-flat/newpixie-flat.slangp"
    static let defaultParams = "curvature=0.0001,vignette=0,use_frame=0"

    // The librashader filter chain, nil until a preset has loaded
    private var chain: libra_mtl_filter_chain_t? = nil

    // Command queue handed to librashader for its own setup work
    private let queue: MTLCommandQueue = ShaderLibrary.device.makeCommandQueue()!

    // Frame counter, which the preset's history passes depend on
    private var frameCount: Int = 0

    // Current values of the preset's parameters, by name
    private var values: [String: Float] = [:]

    // What went wrong, if the preset did not load
    private(set) var loadError: String? = nil

    // Shown instead of the preset while nothing is loaded
    private var fallback = ResampleFilter()

    var path: String {
        let raw = UserDefaults.standard.string(forKey: RetroArchPreset.pathKey) ?? RetroArchPreset.defaultPath
        return NSString(string: raw).expandingTildeInPath
    }

    var overrides: [(String, Float)] {
        let raw = UserDefaults.standard.string(forKey: RetroArchPreset.paramsKey) ?? RetroArchPreset.defaultParams
        return raw.split(separator: ",").compactMap { item in
            let kv = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let v = Float(kv[1]) else { return nil }
            return (kv[0], v)
        }
    }

    init() {

        super.init(name: "RetroArch preset")
        UserDefaults.standard.register(defaults: [RetroArchPreset.pathKey: RetroArchPreset.defaultPath,
                                                  RetroArchPreset.paramsKey: RetroArchPreset.defaultParams])
    }

    override var presets: [String] { ["Posting profile"] }

    override func revertToPreset(nr: Int) {

        for (name, v) in overrides { set(name, v) }
    }

    override func activate() {

        super.activate()
        load()
    }

    override func retire() {

        super.retire()
        unload()
    }

    // Reports a librashader error and frees it
    private func ok(_ error: libra_error_t?, _ what: String) -> Bool {

        guard let error = error else { return true }
        var handle: libra_error_t? = error
        _ = libra_error_print(error)
        _ = libra_error_free(&handle)
        loadError = what
        log("librashader: \(what) failed (see console)", .warning)
        return false
    }

    private func load() {

        unload()
        loadError = nil
        let file = path
        log("Loading RetroArch preset \(file)")

        guard FileManager.default.fileExists(atPath: file) else {
            loadError = "no preset at \(file)"
            log(loadError!, .warning)
            return
        }

        var preset: libra_shader_preset_t? = nil
        guard ok(libra_preset_create(file, &preset), "load \(file)") else { return }

        // The preset's parameters become this shader's settings
        var list = libra_preset_param_list_t()
        var children: [ShaderSetting] = []
        values = [:]
        if ok(libra_preset_get_runtime_params(&preset, &list), "read parameters") {
            for i in 0..<Int(list.length) {
                let p = list.parameters[i]
                let name = String(cString: p.name)
                let desc = p.description != nil ? String(cString: p.description) : ""
                let initial = p.initial
                values[name] = initial
                let binding = Binding(key: name,
                                      get: { [weak self] in self?.values[name] ?? initial },
                                      set: { [weak self] v in self?.set(name, v) })
                let lo = Double(min(p.minimum, p.maximum)), hi = Double(max(p.minimum, p.maximum))
                children.append(ShaderSetting(title: desc.isEmpty ? name : desc,
                                              range: lo == hi ? nil : lo...hi,
                                              step: p.step > 0 ? p.step : 0.01,
                                              value: binding,
                                              help: name))
            }
            _ = libra_preset_free_runtime_params(list)
        }
        settings = [Group(title: "Preset parameters (\(children.count))", children)]

        // The chain consumes the preset
        var options = filter_chain_mtl_opt_t()
        options.version = LIBRASHADER_API_VERSION(LIBRASHADER_CURRENT_VERSION)
        options.force_no_mipmaps = false
        var created: libra_mtl_filter_chain_t? = nil
        guard ok(libra_mtl_filter_chain_create(&preset, queue, &options, &created), "create filter chain") else {
            _ = libra_preset_free(&preset)
            return
        }
        chain = created
        frameCount = 0

        // The posting profile's parameter values on top of the preset's own
        for (name, v) in overrides { set(name, v) }
        log("RetroArch preset loaded: \(children.count) parameters")
    }

    private func unload() {

        if chain != nil {
            _ = libra_mtl_filter_chain_free(&chain)
            chain = nil
        }
    }

    // Sets one preset parameter, on the live chain when there is one
    func set(_ name: String, _ value: Float) {

        values[name] = value
        guard chain != nil else { return }
        if let error = libra_mtl_filter_chain_set_param(&chain, name, value) {
            var e: libra_error_t? = error
            _ = libra_error_free(&e)
            log("parameter \(name) not in this preset", .warning)
        }
    }

    override func apply(commandBuffer: MTLCommandBuffer,
                        in input: MTLTexture, out output: MTLTexture, rect: CGRect) {

        guard chain != nil else {
            fallback.apply(commandBuffer: commandBuffer, in: input, out: output, rect: rect)
            return
        }

        var viewport = libra_viewport_t(x: 0, y: 0,
                                        width: UInt32(output.width), height: UInt32(output.height))
        var options = frame_mtl_opt_t()
        options.version = LIBRASHADER_API_VERSION(LIBRASHADER_CURRENT_VERSION)
        // Never ask for clear_history: with no history passes in the preset the
        // library builds an attachment-less clear pass and Metal refuses it
        // (FailedToCreateCommandBuffer, found 2026-09-25).
        options.clear_history = false
        options.frame_direction = 1
        options.rotation = 0
        options.total_subframes = 1
        options.current_subframe = 1
        options.aspect_ratio = 0
        options.frames_per_second = 60
        options.frametime_delta = 16
        options.brightness_nits = 200

        let error = libra_mtl_filter_chain_frame(&chain, commandBuffer, frameCount,
                                                 input, output, &viewport, nil, &options)
        if !ok(error, "render frame") {
            // Do not hammer the console at 60 fps; fall back until reselected
            unload()
            fallback.apply(commandBuffer: commandBuffer, in: input, out: output, rect: rect)
            return
        }
        frameCount += 1
    }
}
