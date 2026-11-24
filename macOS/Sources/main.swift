import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Localization

/// The UI follows the system language: Spanish if it is preferred, English otherwise.
let isSpanish = (Locale.preferredLanguages.first ?? "en").hasPrefix("es")

func L(_ english: String, _ spanish: String) -> String {
    isSpanish ? spanish : english
}

// MARK: - Settings

enum Settings {
    static let defaults = UserDefaults.standard

    static var interval: TimeInterval {
        get { defaults.object(forKey: "interval") as? Double ?? 30 }
        set { defaults.set(newValue, forKey: "interval") }
    }
    static var distance: Double {
        get { defaults.object(forKey: "distance") as? Double ?? 2 }
        set { defaults.set(newValue, forKey: "distance") }
    }
    static var keepDisplayAwake: Bool {
        get { defaults.object(forKey: "keepDisplayAwake") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepDisplayAwake") }
    }
    static var onlyWhenIdle: Bool {
        get { defaults.object(forKey: "onlyWhenIdle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "onlyWhenIdle") }
    }
    static var pauseForVideo: Bool {
        get { defaults.bool(forKey: "pauseForVideo") }
        set { defaults.set(newValue, forKey: "pauseForVideo") }
    }
    /// Whether the jiggler was running when the app last quit; restored on launch.
    static var wasRunning: Bool {
        get { defaults.bool(forKey: "wasRunning") }
        set { defaults.set(newValue, forKey: "wasRunning") }
    }
}

// MARK: - Jiggler engine

final class Jiggler {
    /// The idle state is checked on this short period; the user-facing "interval"
    /// is the idle time after which the cursor is nudged.
    private static let pollInterval: TimeInterval = 2

    private var timer: Timer?
    private var lastJiggle: TimeInterval = 0
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false

    private(set) var isRunning = false
    /// True while running without the Accessibility permission: macOS silently
    /// drops the synthetic mouse events in that case.
    private(set) var isBlocked = false
    /// Called when `isBlocked` changes so the UI can refresh.
    var onStateChange: (() -> Void)?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastJiggle = now
        applyAssertion()
        let t = Timer(timeInterval: Jiggler.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        isRunning = false
        isBlocked = false
        timer?.invalidate()
        timer = nil
        applyAssertion()
    }

    /// Call after changing settings while running.
    func settingsChanged() {
        applyAssertion()
    }

    private func tick() {
        let blocked = !AXIsProcessTrusted()
        if blocked != isBlocked {
            isBlocked = blocked
            onStateChange?()
        }
        guard !blocked else { return }

        // Our own nudge may or may not reset the system idle counter, so the time
        // since the last nudge is tracked separately and the smaller value wins.
        var idle = now - lastJiggle
        if Settings.onlyWhenIdle {
            let anyInput = CGEventType(rawValue: ~0)!
            idle = min(idle, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
        }
        // Fire one poll early so the idle time never exceeds the chosen interval.
        if idle >= Settings.interval - Jiggler.pollInterval {
            // Moving the cursor would bring up the player controls.
            if Settings.pauseForVideo && Jiggler.isVideoPlaying() { return }
            jiggle()
            lastJiggle = now
        }
    }

    /// True while another app is holding the display awake, which is what video
    /// players, browsers playing video, calls and presentations do.
    static func isVideoPlaying() -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return false
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayTypes = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        for (pid, assertions) in byProcess where pid.int32Value != ownPID {
            for assertion in assertions {
                let type = assertion[kIOPMAssertionTypeKey] as? String ?? ""
                let level = (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.intValue ?? 0
                if level != 0 && displayTypes.contains(type) { return true }
            }
        }
        return false
    }

    private func jiggle() {
        guard let current = CGEvent(source: nil)?.location else { return }
        let moved = CGPoint(x: current.x + CGFloat(Settings.distance), y: current.y)
        post(moved)
        post(current)
    }

    private func post(_ point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let ev = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                         mouseCursorPosition: point, mouseButton: .left)
        ev?.post(tap: .cghidEventTap)
    }

    // MARK: Power assertion (keeps the display on / prevents idle sleep)

    private func applyAssertion() {
        let wanted = isRunning && Settings.keepDisplayAwake
        if wanted && !hasAssertion {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Wiggle is keeping the display awake" as CFString,
                &assertionID)
            hasAssertion = (result == kIOReturnSuccess)
        } else if !wanted && hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
        }
    }
}

// MARK: - Update check

/// Asks GitHub for the latest published release. This is the only network
/// request the app makes, and it only happens when the user asks for it.
enum UpdateChecker {
    static let repository = "danielsolano/wiggle"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    enum Outcome {
        case upToDate
        case newer(String)
        case failed
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Turns "v1.2.3" into [1, 2, 3]; missing or non-numeric parts count as 0.
    static func parts(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let numbers = trimmed.split(separator: ".").map { Int($0) ?? 0 }
        return numbers + Array(repeating: 0, count: max(0, 3 - numbers.count))
    }

    /// Calls `completion` on the main queue.
    static func check(completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wiggle", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var outcome = Outcome.failed
            if let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let isNewer = parts(currentVersion).lexicographicallyPrecedes(parts(tag))
                outcome = isNewer ? .newer(tag) : .upToDate
            }
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }
}

// MARK: - Menu bar glyph

/// The Wiggle "W", drawn from the outline in assets/wiggle-menu.svg so the app
/// needs no image resources and stays sharp at any scale.
enum Glyph {
    /// Width divided by height of the glyph as designed.
    private static let aspect: CGFloat = 1.67

    private static let start = CGPoint(x: 208, y: 541)
    /// Cubic segments in SVG coordinates (y points down): control 1, control 2, end.
    private static let segments: [[CGFloat]] = [
        [195, 483, 227, 444, 273, 434], [327, 422, 373, 453, 382, 512],
        [403, 640, 397, 700, 429, 737], [458, 732, 470, 671, 496, 606],
        [520, 542, 545, 512, 592, 512], [592, 512, 657, 512, 657, 512],
        [728, 512, 747, 575, 771, 664], [785, 720, 797, 737, 813, 737],
        [846, 737, 852, 631, 869, 525], [879, 462, 910, 432, 960, 432],
        [1015, 432, 1054, 476, 1044, 536], [1037, 576, 1004, 672, 977, 739],
        [938, 837, 884, 879, 810, 879], [702, 879, 657, 787, 615, 644],
        [599, 683, 584, 727, 564, 766], [527, 844, 480, 879, 419, 879],
        [342, 879, 294, 815, 259, 721], [241, 671, 221, 597, 208, 541]
    ]

    private static func path(map: (CGFloat, CGFloat) -> CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: map(start.x, start.y))
        for s in segments {
            path.curve(to: map(s[4], s[5]), controlPoint1: map(s[0], s[1]), controlPoint2: map(s[2], s[3]))
        }
        path.close()
        return path
    }

    /// A template image of the given height, so macOS tints it for light and dark menu bars.
    static func image(height: CGFloat) -> NSImage {
        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let source = path { x, y in CGPoint(x: x, y: y) }.bounds
        let image = NSImage(size: size, flipped: true) { rect in
            let fitted = path { x, y in
                CGPoint(x: rect.minX + (x - source.minX) / source.width * rect.width,
                        y: rect.minY + (y - source.minY) / source.height * rect.height)
            }
            NSColor.black.setFill()
            fitted.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wiggle"
        return image
    }
}

// MARK: - App delegate / menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let jiggler = Jiggler()
    private let glyph = Glyph.image(height: 12)
    private var isCheckingForUpdates = false

    private let intervals: [(String, TimeInterval)] = [
        (L("10 seconds", "10 segundos"), 10), (L("30 seconds", "30 segundos"), 30),
        (L("1 minute", "1 minuto"), 60), (L("2 minutes", "2 minutos"), 120),
        (L("5 minutes", "5 minutos"), 300)
    ]
    private let distances: [(String, Double)] = [
        ("1 px", 1), ("2 px", 2), ("5 px", 5), ("10 px", 10), ("25 px", 25)
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu is rebuilt every time it opens, so it always reflects the
        // current state (permission, login item, settings).
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        jiggler.onStateChange = { [weak self] in self?.updateIcon() }
        requestAccessibilityIfNeeded()
        if Settings.wasRunning { jiggler.start() }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        jiggler.stop()
    }

    // MARK: Permissions

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: UI

    private var statusText: String {
        if !jiggler.isRunning { return L("○ Paused", "○ Pausado") }
        if jiggler.isBlocked {
            return L("⚠ Needs Accessibility permission", "⚠ Falta el permiso de Accesibilidad")
        }
        if Settings.pauseForVideo && Jiggler.isVideoPlaying() {
            return L("● Active (paused for video)", "● Activo (en pausa por video)")
        }
        return L("● Active", "● Activo")
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // Full-strength glyph while active, dimmed while paused, and a warning
        // sign while the missing permission keeps the jiggler from working.
        let warning = jiggler.isBlocked
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Wiggle")
            : nil
        warning?.isTemplate = true
        button.image = warning ?? glyph
        button.appearsDisabled = !jiggler.isRunning
        button.toolTip = "Wiggle: " + statusText.dropFirst(2)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let toggle = NSMenuItem(title: jiggler.isRunning ? L("Stop", "Detener") : L("Start", "Iniciar"),
                                action: #selector(toggleRunning), keyEquivalent: "s")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let intervalItem = NSMenuItem(title: L("Interval", "Intervalo"), action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for (label, value) in intervals {
            let item = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = (Settings.interval == value) ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let distItem = NSMenuItem(title: L("Movement distance", "Distancia del movimiento"),
                                  action: nil, keyEquivalent: "")
        let distMenu = NSMenu()
        for (label, value) in distances {
            let item = NSMenuItem(title: label, action: #selector(setDistance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = (Settings.distance == value) ? .on : .off
            distMenu.addItem(item)
        }
        distItem.submenu = distMenu
        menu.addItem(distItem)

        menu.addItem(.separator())

        let idle = NSMenuItem(title: L("Move only when I am idle", "Mover solo si estoy inactivo"),
                              action: #selector(toggleIdle), keyEquivalent: "")
        idle.target = self
        idle.state = Settings.onlyWhenIdle ? .on : .off
        menu.addItem(idle)

        let video = NSMenuItem(title: L("Pause while video is playing", "Pausar mientras se reproduce video"),
                               action: #selector(toggleVideo), keyEquivalent: "")
        video.target = self
        video.state = Settings.pauseForVideo ? .on : .off
        menu.addItem(video)

        let awake = NSMenuItem(title: L("Keep display awake", "Mantener pantalla encendida"),
                               action: #selector(toggleAwake), keyEquivalent: "")
        awake.target = self
        awake.state = Settings.keepDisplayAwake ? .on : .off
        menu.addItem(awake)

        let login = NSMenuItem(title: L("Open at login", "Abrir al iniciar sesión"),
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = isLoginItemEnabled ? .on : .off
        if #unavailable(macOS 13.0) { login.isEnabled = false }
        menu.addItem(login)

        menu.addItem(.separator())

        let ax = NSMenuItem(title: L("Accessibility Permission…", "Permisos de Accesibilidad…"),
                            action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        let about = NSMenuItem(title: L("About Wiggle", "Acerca de Wiggle"),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let update = NSMenuItem(title: L("Check for Updates…", "Buscar actualizaciones…"),
                                action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        let quit = NSMenuItem(title: L("Quit Wiggle", "Salir de Wiggle"),
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func toggleRunning() {
        if jiggler.isRunning {
            jiggler.stop()
        } else {
            requestAccessibilityIfNeeded()
            jiggler.start()
        }
        Settings.wasRunning = jiggler.isRunning
        updateIcon()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.interval = v
    }

    @objc private func setDistance(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.distance = v
    }

    @objc private func toggleIdle() {
        Settings.onlyWhenIdle.toggle()
    }

    @objc private func toggleVideo() {
        Settings.pauseForVideo.toggle()
    }

    @objc private func toggleAwake() {
        Settings.keepDisplayAwake.toggle()
        jiggler.settingsChanged()
    }

    private var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login item", "No se pudo cambiar el inicio automático")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("OK", "Aceptar"))
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        // The copyright line covers from the first release year up to today.
        let firstYear = 2026
        let year = Calendar.current.component(.year, from: Date())
        let years = year > firstYear ? "\(firstYear)–\(year)" : "\(firstYear)"

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let credits = NSMutableAttributedString(
            string: L("Made by Daniel Solano", "Hecho por Daniel Solano") + "\n", attributes: attributes)
        attributes[.link] = URL(string: "https://github.com/\(UpdateChecker.repository)")
        credits.append(NSAttributedString(string: "github.com/\(UpdateChecker.repository)", attributes: attributes))

        // A menu bar app is not frontmost by default; bring the panel forward.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Wiggle",
            .applicationVersion: UpdateChecker.currentVersion,
            .version: "",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): L(
                "Copyright © \(years) Daniel Solano. All rights reserved.",
                "Copyright © \(years) Daniel Solano. Todos los derechos reservados.")
        ])
    }

    @objc private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        UpdateChecker.check { [weak self] outcome in
            self?.isCheckingForUpdates = false
            let alert = NSAlert()
            switch outcome {
            case .newer(let tag):
                alert.messageText = L("A newer version of Wiggle is available",
                                      "Hay una versión más nueva de Wiggle")
                alert.informativeText = L(
                    "You have \(UpdateChecker.currentVersion) and \(tag) is available. If you built Wiggle from the repository, pull the latest changes and build again.",
                    "Tienes la \(UpdateChecker.currentVersion) y está disponible la \(tag). Si compilaste Wiggle desde el repositorio, baja los últimos cambios y vuelve a compilar.")
                alert.addButton(withTitle: L("Open Download Page", "Abrir página de descarga"))
                alert.addButton(withTitle: L("Later", "Más tarde"))
            case .upToDate:
                alert.messageText = L("Wiggle is up to date", "Wiggle está actualizado")
                alert.informativeText = L("You have the latest version (\(UpdateChecker.currentVersion)).",
                                          "Tienes la versión más reciente (\(UpdateChecker.currentVersion)).")
                alert.addButton(withTitle: L("OK", "Aceptar"))
            case .failed:
                alert.messageText = L("Could not check for updates", "No se pudo buscar actualizaciones")
                alert.informativeText = L("GitHub could not be reached, or no release has been published yet.",
                                          "No se pudo contactar a GitHub, o todavía no hay ninguna versión publicada.")
                alert.addButton(withTitle: L("OK", "Aceptar"))
            }
            // A menu bar app is not frontmost by default; bring the alert forward.
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if case .newer = outcome, response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
