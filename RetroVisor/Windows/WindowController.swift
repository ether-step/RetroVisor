// -----------------------------------------------------------------------------
// This file is part of RetroVisor
//
// Copyright (C) Dirk W. Hoffmann. www.dirkwhoffmann.de
// Licensed under the GNU General Public License v3
//
// See https://www.gnu.org for license information
// -----------------------------------------------------------------------------

import Cocoa
import ScreenCaptureKit

@MainActor
class WindowController: NSWindowController, Loggable {

    var viewController: ViewController? { return self.contentViewController as? ViewController }
    var effectWindow: EffectWindow? { return window as? EffectWindow }
    var metalView: MetalView? { return viewController?.metalView }

    // Enables debug output to the console
    nonisolated static let logging: Bool = false

    // Icon bar containing the recorder icon
    var accessory: IconBarViewController?

    // Video source and sink
    var recorder: Recorder { return app.recorder }
    var streamer: Streamer { return app.streamer }

    // Indicates if the window is passive (click-through state)
    var isFrozen: Bool { return window?.ignoresMouseEvents ?? false }

    // chicago95 fork: two small windows that sit on the rounded bottom
    // corners of the window under the overlay, above that window and below
    // the effect window, painting the taskbar's grey outside the corner arc
    // and nothing inside it, so a 4:3 desk reads square-cornered in the
    // capture (the window server rounds every titled window, and a plate
    // underneath would show the window's shadow). Defaults: Plate (bool,
    // on), PlateColor ("r,g,b", 192,192,192), PlateRadius (points, 18).
    private var fillers: [NSPanel] = []
    static let plateKey = "Plate"
    static let plateColorKey = "PlateColor"
    static let plateRadiusKey = "PlateRadius"

    private func plateColor() -> NSColor {

        let raw = UserDefaults.standard.string(forKey: WindowController.plateColorKey) ?? "192,192,192"
        let c = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard c.count == 3 else { return NSColor(white: 192.0 / 255.0, alpha: 1) }
        return NSColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1)
    }

    // The frontmost normal-level window of another app that contains the
    // whole overlay (within 2 points), as an NSRect (bottom-left origin), or
    // nil. Requiring the whole frame skips sheets, alerts and palettes that
    // happen to sit over the middle of the target window.
    private func windowBelow(_ frame: NSRect) -> NSRect? {

        guard let primary = NSScreen.screens.first else { return nil }
        let want = CGRect(x: frame.minX, y: primary.frame.height - frame.maxY,
                          width: frame.width, height: frame.height).insetBy(dx: 2, dy: 2)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict) else { continue }
            if cg.contains(want) {
                return NSRect(x: cg.minX, y: primary.frame.height - cg.maxY, width: cg.width, height: cg.height)
            }
        }
        return nil
    }

    private func showPlate(under frame: NSRect) {

        // Off unless asked for: the capture's corners are squared on the GPU
        // now (squareCorners in Shaders.metal), which follows whatever the
        // window shows; a fixed-colour filler showed as an arc on a dark desk
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: WindowController.plateKey) { hidePlate(); return }
        guard let below = windowBelow(frame) else { log("no window under the overlay; no corner fillers"); hidePlate(); return }

        let r = CGFloat(defaults.object(forKey: WindowController.plateRadiusKey) != nil
                        ? defaults.double(forKey: WindowController.plateRadiusKey) : 18)
        let color = plateColor()
        let frames = [NSRect(x: below.minX, y: below.minY, width: r, height: r),
                      NSRect(x: below.maxX - r, y: below.minY, width: r, height: r)]
        let corners: [CornerFillerView.Corner] = [.bottomLeft, .bottomRight]

        if fillers.count != 2 {
            fillers.forEach { $0.orderOut(nil) }
            fillers = corners.map { corner in
                let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: r, height: r),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.level = .floating
                p.ignoresMouseEvents = true
                p.hasShadow = false
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hidesOnDeactivate = false
                p.isReleasedWhenClosed = false
                p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                let v = CornerFillerView(frame: NSRect(x: 0, y: 0, width: r, height: r))
                v.corner = corner
                p.contentView = v
                return p
            }
        }
        for (i, p) in fillers.enumerated() {
            let v = p.contentView as! CornerFillerView
            v.color = color; v.radius = r; v.needsDisplay = true
            p.setFrame(frames[i], display: true)
            p.order(.below, relativeTo: window!.windowNumber)
        }
        log("corner fillers on \(below) radius \(r)")
    }

    private func hidePlate() {

        fillers.forEach { $0.orderOut(nil) }
    }

    // Indicates if the window is invisible (but still active)
    var invisible: Bool = false {
        didSet {
            if invisible {
                window?.isOpaque = false
                window?.backgroundColor = .clear
                window?.isMovable = false
                window?.alphaValue = 0.0
            } else {
                window?.isOpaque = true
                window?.isMovable = true
                window?.alphaValue = 1.0
            }
        }
    }

    override func windowDidLoad() {

        print("windowDidLoad")
        super.windowDidLoad()

        let window = self.window as! EffectWindow

        // Setup the window
        window.hasShadow = true
        window.level = .floating
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.trackingDelegate = self
        // Remember the effect window's frame between launches (chicago95 fork)
        window.setFrameAutosaveName("EffectWindow")
        window.makeKeyAndOrderFront(nil)
        unfreeze()

        // Setup the streamer
        streamer.delegate = self
        streamer.window = effectWindow

        // Setup the recorder
        recorder.delegate = self

        // Launch the streamer
        streamer.enqueue(.start)

        // chicago95 fork: snap to and follow a named window
        startFollowing()
    }

    //
    // chicago95 fork: follow a window. The effect window takes the frame of
    // the window titled FollowWindow (default "chicago95") owned by
    // FollowOwner (default "UTM"), less FollowTopInset points at the top
    // (default 40, the VM window's title bar), freezes itself the first time
    // it finds it (AutoFreeze, default on), keeps to it while frozen, and
    // hides while the window is gone (minimized, closed). Set FollowWindow to
    // "" for the stock behaviour. Unfreeze from the menu to place it by hand;
    // freezing again snaps it back.
    //

    private var followTimer: Timer?
    private var autoFrozen = false
    private var hiddenForFollow = false

    static func registerFollowDefaults() {

        UserDefaults.standard.register(defaults: ["FollowWindow": "chicago95",
                                                  "FollowOwner": "UTM",
                                                  "FollowTopInset": 40.0,
                                                  "AutoFreeze": true])
    }

    var following: Bool { !(UserDefaults.standard.string(forKey: "FollowWindow") ?? "").isEmpty }

    func startFollowing() {

        WindowController.registerFollowDefaults()
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                           selector: #selector(followTick),
                                           userInfo: nil, repeats: true)
    }

    private func followTarget() -> NSRect? {

        let d = UserDefaults.standard
        guard let title = d.string(forKey: "FollowWindow"), !title.isEmpty,
              let primary = NSScreen.screens.first else { return nil }
        let owner = d.string(forKey: "FollowOwner") ?? "UTM"
        let inset = CGFloat(d.double(forKey: "FollowTopInset"))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == owner,
                  (w[kCGWindowName as String] as? String) == title,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict),
                  cg.height > inset + 10 else { continue }
            return NSRect(x: cg.minX, y: primary.frame.height - cg.maxY,
                          width: cg.width, height: cg.height - inset)
        }
        return nil
    }

    @objc private func followTick() {

        guard following, let window = window else { return }

        guard let target = followTarget() else {
            // The window is gone: do not shade whatever is behind it
            if !hiddenForFollow { window.alphaValue = 0; hiddenForFollow = true }
            return
        }
        if hiddenForFollow { window.alphaValue = 1; hiddenForFollow = false }

        let f = window.frame
        let moved = abs(f.minX - target.minX) > 0.5 || abs(f.minY - target.minY) > 0.5 ||
                    abs(f.width - target.width) > 0.5 || abs(f.height - target.height) > 0.5

        if !isFrozen {
            // Freeze once by itself; after a manual unfreeze leave it to the user
            guard UserDefaults.standard.bool(forKey: "AutoFreeze"), !autoFrozen else { return }
            window.setFrame(target, display: true)
            freeze()
            autoFrozen = true
            log("following \(UserDefaults.standard.string(forKey: "FollowWindow") ?? ""): frozen at \(target)")
            return
        }
        if moved { window.setFrame(target, display: true) }
    }

    func showPermissionAlert() {

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        This app needs screen recording permission to capture content.
        Please enable it in System Settings › Privacy & Security › Screen Recording, then restart the app.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func freeze() {

        let window = self.window as! TrackingWindow

        window.ignoresMouseEvents = true
        // Borderless while frozen: a titled window keeps the window server's
        // rounded corners whatever its layer says. The style change moves the
        // frame (AppKit keeps the content layout rect, 32 points short at the
        // top), so put the frame back afterwards (chicago95 fork).
        let frame = window.frame
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.setFrame(frame, display: true)
        showPlate(under: frame)

        Task { @MainActor [weak self] in

            // Wait one runloop cycle after styleMask change
            try? await Task.sleep(nanoseconds: 0)

            if let contentView = self?.window!.contentView {

                contentView.wantsLayer = true
                let layer = self!.window!.contentView!.layer!
                layer.borderWidth = 0
                layer.cornerRadius = 0
            }
        }
    }

    func unfreeze() {

        let window = self.window as! TrackingWindow

        window.ignoresMouseEvents = false
        let frame = window.frame
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable,
                            .nonactivatingPanel, .fullSizeContentView]
        window.setFrame(frame, display: true)
        hidePlate()

        Task { @MainActor [weak self] in

            // Wait one runloop cycle after styleMask change
            try? await Task.sleep(nanoseconds: 0)

            if let contentView = self?.window!.contentView {

                contentView.wantsLayer = true
                let layer = self!.window!.contentView!.layer!
                layer.borderColor = NSColor.systemBlue.cgColor
                layer.borderWidth = 2
                layer.cornerRadius = NSWindow.cornerRadius
            }
        }
    }
}

@MainActor
extension WindowController: TrackingWindowDelegate {

    func windowDidStartResize(_ window: TrackingWindow) {

        metalView!.intensity.target = 1.0
        metalView!.intensity.steps = 15
    }

    func windowDidStopResize(_ window: TrackingWindow) {

        let width = NSScreen.scaleFactor * Int(window.frame.width)
        let height = NSScreen.scaleFactor * Int(window.frame.height)

        metalView!.intensity.target = 0.0
        metalView!.intensity.steps = 15
        
        metalView!.dstSize = MTLSize(width: width, height: height, depth: 1)

        // metalView!.updateTextures(rect: window.frame)

        streamer.updateRects()
        streamer.relaunchIfNeeded()
    }

    func windowDidStartDrag(_ window: TrackingWindow) {

        metalView!.intensity.target = 1.0
        metalView!.intensity.steps = 25
    }

    func windowDidStopDrag(_ window: TrackingWindow) {

        metalView!.intensity.target = 0.0
        metalView!.intensity.steps = 25

        streamer.updateRects()
        streamer.relaunchIfNeeded()
    }

    func windowWasDoubleClicked(_ window: TrackingWindow) {

        freeze()
    }

    func windowDidChangeScreen(_ window: TrackingWindow) {

        streamer.enqueue(.start)
    }
}

@MainActor
extension WindowController: StreamerDelegate {

    func textureRectDidChange(rect: CGRect?) {

        metalView?.textureRectDidChange(rect)
    }

    func captureRectDidChange(rect: CGRect?) {

    }

    func streamDidStop(error: Error?) {

        if let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil) {
            effectWindow?.showPauseOverlay(image: image) {
                app.streamer.enqueue(.start)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {

        switch type {

        case .screen:

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            let timeStamp = CMSampleBufferGetPresentationTimeStamp(buffer)

            Task { @MainActor [weak self] in
                                
                if let controller = self?.contentViewController as? ViewController {
                    
                    //self?.recorder.timestamp = timeStamp
                    controller.metalView.update(with: pixelBuffer, timeStamp: timeStamp)
                }
            }

        case .audio:

            Task { @MainActor [weak self] in

                self?.recorder.appendAudio(buffer: buffer)
            }

        default:
            break
        }
    }
}

extension WindowController: RecorderDelegate {

    func recorderDidStart() {

        app.updateStatusBarMenuIcon(recording: true)
    }

    func recorderDidStop() {

        app.updateStatusBarMenuIcon(recording: false)
    }
}

// Paints a colour outside a quarter-disc whose centre is the square's inner
// corner, and nothing inside it: the piece a rounded window corner leaves out.
final class CornerFillerView: NSView {

    enum Corner { case bottomLeft, bottomRight }
    var corner: Corner = .bottomLeft
    var color: NSColor = .gray
    var radius: CGFloat = 18

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {

        color.setFill()
        bounds.fill()
        let c = corner == .bottomLeft ? NSPoint(x: bounds.maxX, y: bounds.maxY)
                                      : NSPoint(x: bounds.minX, y: bounds.maxY)
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                               width: 2 * radius, height: 2 * radius))
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        disc.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
