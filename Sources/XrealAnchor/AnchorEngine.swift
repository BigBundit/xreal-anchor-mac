import AppKit
import ScreenCaptureKit
import Metal
import Combine
import simd
import XrealKit

/// Ties everything together: head tracking, the virtual display, capture and the
/// full-screen renderer on the glasses.
final class AnchorEngine: ObservableObject {
    static let shared = AnchorEngine()

    // MARK: Published status for the UI

    @Published private(set) var glassesModel: String?
    @Published private(set) var glassesScreenName: String?
    @Published private(set) var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var calibrated = false
    @Published private(set) var calibrationProgress: Float?
    @Published private(set) var renderFPS = 0
    @Published private(set) var imuRate = 0
    @Published private(set) var temperature: Float = 0
    @Published private(set) var lastError: String?
    @Published private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var yawPitchDegrees: (Float, Float) = (0, 0)

    let settings = Settings.shared

    private let imu = XrealIMU()
    private let mcu = XrealMCU()
    let tracker = HeadTracker()

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var capture = ScreenCapture(device: device)
    private var renderLoop: RenderLoop?
    private var window: NSWindow?
    private lazy var pose = PoseSolver(tracker: tracker)
    private var virtualDisplay: VirtualDisplay?

    private var glassesDisplayID: CGDirectDisplayID?
    private var statusTimer: Timer?
    private var cursorTimer: Timer?
    private var lastBrightnessPress: CFTimeInterval = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        imu.onSample = { [tracker] sample in tracker.process(sample) }
        imu.onConnectionChange = { [weak self] model in
            DispatchQueue.main.async {
                self?.glassesModel = model?.name
                if model != nil { self?.tracker.reset() }
            }
        }
        mcu.onButton = { [weak self] button in
            DispatchQueue.main.async { self?.handleButton(button) }
        }
    }

    func launch() {
        Log.info("launch: permission=\(CGPreflightScreenCaptureAccess()) glasses screen=\(findGlassesScreen()?.localizedName ?? "none")")
        if let saved = UserDefaults.standard.array(forKey: "gyroBias") as? [Float], saved.count == 3 {
            tracker.gyroBias = SIMD3(saved[0], saved[1], saved[2])
        }
        imu.start()
        mcu.start()
        refreshGlassesScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateStatus() }

        // Settings that need the virtual display rebuilt.
        settings.$resolutionID.dropFirst().removeDuplicates().sink { [weak self] _ in self?.restartIfActive() }.store(in: &cancellables)
        settings.$hiDPI.dropFirst().removeDuplicates().sink { [weak self] _ in self?.restartIfActive() }.store(in: &cancellables)
        settings.$showCursor.dropFirst().removeDuplicates().sink { [weak self] _ in self?.restartIfActive() }.store(in: &cancellables)
        settings.$mode.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.recenter() } }.store(in: &cancellables)
        // Hand the render thread a fresh copy of the settings whenever one changes.
        pose.update(PoseConfig(settings))
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.pose.update(PoseConfig(self.settings)) }
        }.store(in: &cancellables)

        if settings.autoStart, glassesScreenName != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
        }
    }

    func shutdown() {
        saveBias()
        stopSync(immediately: true)
        imu.stop()
        mcu.stop()
    }

    // MARK: Glasses display detection

    /// The physical display of the glasses, if connected.
    private func findGlassesScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let id = screen.displayID
            if id == virtualDisplay?.displayID || CGDisplayVendorNumber(id) == 0x3318 { return false }
            let name = screen.localizedName.lowercased()
            return CGDisplayVendorNumber(id) == 0x3647 || name.contains("xreal") || name.contains("nreal")
                || name == "air" || name.hasPrefix("air ") || name.contains("air 2") || name.contains("one pro")
        }
    }

    private func refreshGlassesScreen() {
        let screen = findGlassesScreen()
        glassesScreenName = screen?.localizedName
        glassesDisplayID = screen?.displayID
    }

    private func screensChanged() {
        let wasPresent = glassesScreenName != nil
        refreshGlassesScreen()
        if isActive {
            if let screen = findGlassesScreen() {
                if let window, window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            } else {
                // Rearranging displays briefly hides screens; only stop if the glasses stay gone.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard self.isActive, self.findGlassesScreen() == nil else { return }
                    Log.info("glasses display disappeared")
                    self.stop()
                }
            }
        } else if !wasPresent, glassesScreenName != nil, settings.autoStart, !isStarting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.start() }
        }
    }

    // MARK: Start / stop

    func toggle() { isActive || isStarting ? stop() : start() }

    func start() {
        Log.info("start requested (active=\(isActive) starting=\(isStarting))")
        guard !isActive, !isStarting else { return }
        lastError = nil
        guard let screen = findGlassesScreen() else {
            lastError = "ไม่พบจอของแว่น XREAL — เสียบสายแว่นก่อน"
            Log.info("glasses screen not found; screens: \(NSScreen.screens.map { "\($0.localizedName)#\($0.displayID) vendor \(CGDisplayVendorNumber($0.displayID))" })")
            return
        }
        isStarting = true
        let glassesID = screen.displayID
        glassesDisplayID = glassesID

        Task { @MainActor in
            // Ask ScreenCaptureKit directly: CGPreflightScreenCaptureAccess can report stale
            // answers, while this call both checks and (if needed) triggers the system prompt.
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                self.hasScreenPermission = true
            } catch {
                Log.info("screen recording not permitted: \(error)")
                CGRequestScreenCaptureAccess()
                self.hasScreenPermission = false
                self.lastError = "ต้องอนุญาต Screen Recording ให้แอปนี้ก่อน (System Settings › Privacy & Security › Screen & System Audio Recording) แล้วเปิดแอปใหม่"
                self.isStarting = false
                return
            }

            let preset = self.settings.resolution
            guard let vd = VirtualDisplay(preset: preset, hiDPI: self.settings.hiDPI) else {
                self.isStarting = false
                self.lastError = "สร้างจอเสมือนไม่สำเร็จ"
                Log.info("virtual display creation failed")
                return
            }
            self.virtualDisplay = vd
            Log.info("virtual display created: \(vd.displayID) \(preset.id) hiDPI=\(self.settings.hiDPI)")

            // Give WindowServer a moment to bring the new display online.
            try? await Task.sleep(nanoseconds: 600_000_000)
            vd.ensureHiDPIMode()
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.arrangeDisplays(virtualID: vd.displayID, glassesID: glassesID)
            let px = vd.pixelSize
            do {
                try await self.capture.start(displayID: vd.displayID, width: px.width, height: px.height,
                                             showsCursor: self.settings.showCursor)
            } catch {
                self.lastError = "เริ่มจับภาพจอไม่ได้: \(error.localizedDescription)"
                Log.info("capture start failed: \(error)")
                self.isStarting = false
                self.stopSync()
                return
            }
            self.capture.onError = { error in
                DispatchQueue.main.async {
                    let engine = AnchorEngine.shared
                    guard engine.isActive else { return }
                    engine.lastError = "การจับภาพหยุด: \(error.localizedDescription)"
                    engine.stop()
                }
            }
            guard let screen = self.findGlassesScreen() else {
                self.isStarting = false
                self.stopSync()
                return
            }
            self.openWindow(on: screen)
            Log.info("active: virtual display \(vd.displayID) \(px.width)x\(px.height)px on \(screen.localizedName) (\(screen.displayID))")
            self.recenter()
            self.isStarting = false
            self.isActive = true
            self.startCursorGuard()
        }
    }

    func stop() {
        Log.info("stop requested")
        stopSync()
    }

    private func stopSync(immediately: Bool = false) {
        if isActive || isStarting { Log.info("stopping") }
        cursorTimer?.invalidate()
        cursorTimer = nil
        renderLoop?.stop()
        renderLoop = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil

        let cap = capture
        Task { await cap.stop() }
        let wasRunning = virtualDisplay != nil
        virtualDisplay = nil
        if wasRunning { restoreDisplays(immediately: immediately) }
        isActive = false
        isStarting = false
    }

    private func restartIfActive() {
        guard isActive else { return }
        stopSync()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.start() }
    }

    // MARK: Window on the glasses

    private func openWindow(on screen: NSScreen) {
        guard let renderer = Renderer(device: device) else {
            lastError = "เริ่ม Metal renderer ไม่ได้"
            return
        }

        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.setFrame(screen.frame, display: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.title = "XREAL Anchor"

        let view = GlassesView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        win.contentView = view
        win.orderFrontRegardless()
        view.layout()
        window = win

        let loop = RenderLoop(layer: view.metalLayer, renderer: renderer,
                              pose: { [pose] time in pose.frame(presentTime: time) },
                              texture: { [capture] in capture.texture })
        if let margin = UserDefaults.standard.object(forKey: "renderMarginMs") as? Double {
            loop.renderMargin = margin / 1000
        }
        Log.info("render margin \(loop.renderMargin * 1000) ms")
        loop.start()
        renderLoop = loop
    }

    // MARK: Pose

    func recenter() { pose.recenter() }

    func calibrate() { tracker.startCalibration() }

    // MARK: Display arrangement & cursor

    /// Puts the virtual display where the glasses used to be (or right of the main display)
    /// and parks the glasses' own panel diagonally off a corner, so the pointer flows into
    /// the virtual screen but rarely reaches the panel that only shows our renderer.
    private func arrangeDisplays(virtualID: CGDirectDisplayID, glassesID: CGDirectDisplayID) {
        guard CGMainDisplayID() != glassesID else { return }
        let others = activeDisplays().filter { $0 != glassesID && $0 != virtualID }.map { CGDisplayBounds($0) }
        let glassesBounds = CGDisplayBounds(glassesID)

        // Remember the user's own placement of the glasses, unless it is our parked spot.
        if AnchorEngine.sharesEdge(glassesBounds, with: others) {
            UserDefaults.standard.set([glassesBounds.minX, glassesBounds.minY], forKey: "glassesHomeOrigin")
        }
        let home = glassesHomeOrigin

        let size = CGSize(width: settings.resolution.width, height: settings.resolution.height)
        var virtualRect = CGRect(origin: home, size: size)
        if !AnchorEngine.sharesEdge(virtualRect, with: others) || others.contains(where: { $0.intersects(virtualRect) }) {
            let main = CGDisplayBounds(CGMainDisplayID())
            virtualRect.origin = CGPoint(x: main.maxX, y: main.minY)
        }
        let all = others.reduce(virtualRect) { $0.union($1) }
        let parked = CGPoint(x: all.maxX, y: all.maxY)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, virtualID, Int32(virtualRect.minX), Int32(virtualRect.minY))
        CGConfigureDisplayOrigin(config, glassesID, Int32(parked.x), Int32(parked.y))
        let r = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("arranged: virtual at \(virtualRect.origin), glasses parked at \(parked) (\(r.rawValue))")
    }

    /// Where the glasses' panel sits when the app is not running.
    private var glassesHomeOrigin: CGPoint {
        if let v = UserDefaults.standard.array(forKey: "glassesHomeOrigin") as? [Double], v.count == 2 {
            return CGPoint(x: v[0], y: v[1])
        }
        let main = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: main.maxX, y: main.minY)
    }

    /// Moves the glasses' panel back to where the user had it.
    private func restoreDisplays(immediately: Bool = false) {
        guard let id = glassesDisplayID else { return }
        let origin = glassesHomeOrigin
        let apply = {
            guard CGDisplayIsOnline(id) != 0 else { return }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
            CGCompleteDisplayConfiguration(config, .forSession)
        }
        if immediately {
            // Quitting: let WindowServer drop the virtual display before moving the panel back.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            apply()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: apply)
        }
    }

    /// True when `rect` touches one of `others` along an edge (not just at a corner).
    static func sharesEdge(_ rect: CGRect, with others: [CGRect]) -> Bool {
        others.contains { o in
            let vertical = (rect.minX == o.maxX || rect.maxX == o.minX) && min(rect.maxY, o.maxY) - max(rect.minY, o.minY) > 0
            let horizontal = (rect.minY == o.maxY || rect.maxY == o.minY) && min(rect.maxX, o.maxX) - max(rect.minX, o.minX) > 0
            return vertical || horizontal
        }
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    /// Keeps the pointer off the glasses' physical panel, which only shows our renderer.
    private func startCursorGuard() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self, self.settings.guardCursor, let gid = self.glassesDisplayID,
                  let location = CGEvent(source: nil)?.location else { return }
            let gb = CGDisplayBounds(gid)
            guard gb.contains(location) else { return }
            var best: CGPoint?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for id in self.activeDisplays() where id != gid {
                let b = CGDisplayBounds(id).insetBy(dx: 1, dy: 1)
                let p = CGPoint(x: min(max(location.x, b.minX), b.maxX), y: min(max(location.y, b.minY), b.maxY))
                let dist = hypot(p.x - location.x, p.y - location.y)
                if dist < bestDistance { bestDistance = dist; best = p }
            }
            if let best {
                CGWarpMouseCursorPosition(best)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
        RunLoop.main.add(cursorTimer!, forMode: .common)
    }

    // MARK: Buttons & status

    private func handleButton(_ button: XrealMCU.Button) {
        guard settings.buttonRecenter else { return }
        switch button {
        case .brightnessUp, .brightnessDown:
            let now = CACurrentMediaTime()
            if now - lastBrightnessPress < 0.6 {
                recenter()
                lastBrightnessPress = 0
            } else {
                lastBrightnessPress = now
            }
        default:
            break
        }
    }

    private var lastBiasSave = Date()
    private var statusTicks = 0

    private func saveBias() {
        guard let b = tracker.gyroBias else { return }
        UserDefaults.standard.set([b.x, b.y, b.z], forKey: "gyroBias")
        lastBiasSave = Date()
    }

    private func updateStatus() {
        if Date().timeIntervalSince(lastBiasSave) > 30 { saveBias() }
        let s = tracker.snapshot()
        if calibrated != s.calibrated { calibrated = s.calibrated }
        if calibrationProgress != s.calibrationProgress { calibrationProgress = s.calibrationProgress }
        let rate = Int(s.sampleRate.rounded())
        if imuRate != rate { imuRate = rate }
        temperature = s.temperature
        statusTicks += 1
        if let loop = renderLoop, statusTicks % 4 == 0 {
            let stats = loop.takeStats()
            if renderFPS != stats.fps { renderFPS = stats.fps }
            if statusTicks % 240 == 0 {
                Log.info(String(format: "render %d fps, worst gap %.1f ms, slow frames %d, pose→screen %.1f ms (target off by %+.1f), look-ahead %.1f ms",
                                stats.fps, stats.worstGapMs, stats.slowFrames, stats.poseToScreenMs, stats.targetErrorMs, pose.lastLookAheadMs))
            }
        } else if renderLoop == nil, renderFPS != 0 {
            renderFPS = 0
        }
        yawPitchDegrees = pose.relativeYawPitch()
        if !hasScreenPermission, CGPreflightScreenCaptureAccess() { hasScreenPermission = true }
    }

    // MARK: Shortcuts

    /// Runs a shortcut and shows what happened on screen (in the glasses when anchoring is on).
    func perform(_ action: ShortcutAction) {
        var title = action.title
        var detail: String?
        var icon = action.icon
        switch action {
        case .toggleLock:
            let turningOn = !(isActive || isStarting)
            toggle()
            title = turningOn ? "เปิดการล็อคจอ" : "ปิดการล็อคจอ"
            icon = turningOn ? "lock.fill" : "lock.open"
            detail = turningOn ? "กำลังสร้างจอเสมือน…" : "แว่นกลับไปแสดงผลแบบปกติ"
        case .recenter:
            recenter()
            detail = "จออยู่ตรงที่คุณมองตอนนี้"
        case .modeAnchored, .modeFollow, .modeHeadLocked, .cycleMode:
            switch action {
            case .modeAnchored: settings.mode = .anchored
            case .modeFollow: settings.mode = .follow
            case .modeHeadLocked: settings.mode = .headLocked
            default: cycleMode()
            }
            title = settings.mode.title
            icon = ShortcutAction.forMode(settings.mode).icon
        case .bigger, .smaller:
            adjustScreenSize(by: action == .bigger ? 3 : -3)
            detail = String(format: "ขนาดจอ %.0f°", settings.screenAngle)
        case .resetSize:
            settings.screenAngle = 36
            detail = "ขนาดจอ 36°"
        case .curved:
            settings.curved.toggle()
            title = settings.curved ? "จอโค้ง" : "จอแบน"
        case .nudgeUp, .nudgeDown, .nudgeLeft, .nudgeRight:
            let step: Float = 2
            switch action {
            case .nudgeUp: pose.nudge(yawDegrees: 0, pitchDegrees: step)
            case .nudgeDown: pose.nudge(yawDegrees: 0, pitchDegrees: -step)
            case .nudgeLeft: pose.nudge(yawDegrees: step, pitchDegrees: 0)
            default: pose.nudge(yawDegrees: -step, pitchDegrees: 0)
            }
            detail = "ทีละ 2°"
        case .stabilize:
            settings.stabilize.toggle()
            title = settings.stabilize ? "ลดภาพสั่น: เปิด" : "ลดภาพสั่น: ปิด"
        case .calibrate:
            calibrate()
            detail = "วางแว่นนิ่งๆ บนโต๊ะ 3 วินาที"
        case .tuningGrid:
            settings.tuningGrid.toggle()
            title = settings.tuningGrid ? "โหมดจูน: เปิด" : "โหมดจูน: ปิด"
            detail = settings.tuningGrid ? "ส่ายหัวช้าๆ แล้วปรับ [ ] และ , . จนกริดนิ่ง" : nil
        case .fovDown, .fovUp:
            settings.glassesFOV = min(max(settings.glassesFOV + (action == .fovUp ? 0.5 : -0.5), 30), 60)
            detail = String(format: "FOV %.1f° — ถ้าจอวิ่งตามหัวให้ลด ถ้าวิ่งสวนให้เพิ่ม", settings.glassesFOV)
        case .predictionDown, .predictionUp:
            settings.predictionMs = min(max(settings.predictionMs + (action == .predictionUp ? 1 : -1), -10), 30)
            detail = String(format: "ทำนายเพิ่ม %+.0f ms — จอหน่วงตามหลังให้เพิ่ม เด้งเลยให้ลด", settings.predictionMs)
        }
        HUD.shared.show(icon: icon, title: title, detail: detail, keys: action.display, on: hudScreen)
    }

    /// The virtual display while anchoring (so the HUD is seen in the glasses), else the main screen.
    private var hudScreen: NSScreen? {
        if isActive, let id = virtualDisplay?.displayID, let s = NSScreen.screens.first(where: { $0.displayID == id }) {
            return s
        }
        return NSScreen.main
    }

    func adjustScreenSize(by delta: Double) {
        settings.screenAngle = min(max(settings.screenAngle + delta, 15), 120)
    }

    func cycleMode() {
        let all = TrackingMode.allCases
        let i = all.firstIndex(of: settings.mode) ?? 0
        settings.mode = all[(i + 1) % all.count]
    }
}

extension ShortcutAction {
    static func forMode(_ mode: TrackingMode) -> ShortcutAction {
        switch mode {
        case .anchored: return .modeAnchored
        case .follow: return .modeFollow
        case .headLocked: return .modeHeadLocked
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
