// Claude Profiles — routes claude:// links to the right Claude Desktop profile.
//
// Claude Desktop is an Electron app, so every `--user-data-dir` gives an
// independent profile (its own account, chats and settings). macOS, however,
// delivers a claude:// link (sign-in callbacks, connector OAuth, deep links)
// to whichever instance it likes. This helper registers itself as the claude://
// handler, figures out which profiles are running and, when there is a choice,
// asks which one should receive the link.

import AppKit
import Carbon.HIToolbox
import CoreServices
import Darwin

let helperBundleID = "com.claudeprofiles.helper"
let claudeBundleID = "com.anthropic.claudefordesktop"
let scheme = "claude"

// MARK: - Localisation

let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
func L(_ en: String, _ ru: String) -> String { isRussian ? ru : en }

// MARK: - Configuration

struct Profile: Codable, Equatable {
    var id: String
    var name: String
    /// nil / empty means the stock profile (no --user-data-dir).
    var userDataDir: String?
    /// Optional .app or .icns whose icon is shown in the chooser.
    var icon: String?
    /// Global shortcut such as "ctrl+opt+1"; "none" turns it off. Missing means the default
    /// ⌃⌥<position> for the first nine profiles.
    var hotkey: String?
    /// Dock launcher app made for this profile (Settings → Add to Dock).
    var launcher: String?
    /// Tint of the Claude icon for this profile (see ProfileColor). Missing means "next in the palette".
    var color: String?

    var dataDir: String? {
        guard let d = userDataDir, !d.isEmpty else { return nil }
        return (d as NSString).expandingTildeInPath
    }
}

struct Config: Codable {
    var appPath: String
    var profiles: [Profile]
    /// Ask even when only one profile is running.
    var alwaysAsk: Bool?

    static var directory: String {
        ProcessInfo.processInfo.environment["CLAUDE_PROFILES_HOME"]
            ?? NSHomeDirectory() + "/Library/Application Support/Claude Profiles"
    }
    static var path: String { directory + "/profiles.json" }

    static func load() throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let c = try JSONDecoder().decode(Config.self, from: data)
        guard !c.profiles.isEmpty else { throw NSError(domain: "ClaudeProfiles", code: 1) }
        return c
    }

    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: Config.path), options: .atomic)
    }
}

// MARK: - Processes

/// Exact argv of a process, read via sysctl(KERN_PROCARGS2). Avoids parsing `ps` output,
/// which joins arguments with spaces and breaks on paths like "Application Support".
func arguments(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
    var i = MemoryLayout<Int32>.size
    while i < size && buf[i] != 0 { i += 1 }  // executable path
    while i < size && buf[i] == 0 { i += 1 }  // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

func userDataDir(in args: [String]) -> String? {
    for (n, a) in args.enumerated() {
        if a.hasPrefix("--user-data-dir=") { return String(a.dropFirst("--user-data-dir=".count)) }
        if a == "--user-data-dir", n + 1 < args.count { return args[n + 1] }
    }
    return nil
}

func normalised(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}

/// Running Claude main processes keyed by profile id. A profile with several matches is skipped,
/// so a link is never sent to an ambiguous target.
func runningProfiles(_ c: Config) -> [String: NSRunningApplication] {
    let app = normalised(c.appPath)
    let instances = NSWorkspace.shared.runningApplications.compactMap { r -> (NSRunningApplication, String?)? in
        guard let url = r.bundleURL, normalised(url.path) == app, let args = arguments(of: r.processIdentifier) else { return nil }
        return (r, userDataDir(in: args).map(normalised))
    }
    var result: [String: NSRunningApplication] = [:]
    for p in c.profiles {
        let want = p.dataDir.map(normalised)
        let matches = instances.filter { $0.1 == want }
        if matches.count == 1 { result[p.id] = matches[0].0 }
    }
    return result
}

func launch(_ p: Profile, _ c: Config) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var args = ["-n", "-a", c.appPath]
    if let dir = p.dataDir { args += ["--args", "--user-data-dir=" + dir] }
    task.arguments = args
    try task.run(); task.waitUntilExit()
    if task.terminationStatus != 0 { throw NSError(domain: "ClaudeProfiles", code: 2) }
}

// MARK: - URL handling

let kGURL = AEEventClass(0x4755524c)  // 'GURL'
let keyDirectObject = AEKeyword(0x2d2d2d2d)  // '----'

func isAcceptable(_ raw: String) -> Bool {
    guard raw.utf8.count <= 65536, !raw.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }),
          let u = URLComponents(string: raw) else { return false }
    return u.scheme?.lowercased() == scheme && u.user == nil && u.password == nil
}

/// Hands the URL to one specific process with the same Apple Event macOS would send.
func deliver(_ raw: String, to app: NSRunningApplication) throws {
    let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
    let event = NSAppleEventDescriptor(eventClass: kGURL, eventID: kGURL, targetDescriptor: target,
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: raw), forKeyword: keyDirectObject)
    _ = try event.sendEvent(options: [.waitForReply], timeout: 10)
}

func currentHandler() -> String {
    LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String? ?? ""
}
@discardableResult func setHandler(_ id: String) -> OSStatus {
    LSSetDefaultHandlerForURLScheme(scheme as CFString, id as CFString)
}

func alert(_ title: String, _ text: String) {
    let a = NSAlert(); a.messageText = title; a.informativeText = text
    NSApp.activate(ignoringOtherApps: true); a.runModal()
}

// MARK: - Chooser window

/// The Claude icon, recoloured per profile by rotating its hue. Orange is Claude's own colour.
enum ProfileColor: String, CaseIterable {
    case orange, blue, green, yellow, purple, pink, teal, graphite

    /// Hue rotation from Claude's orange, in degrees.
    var hueShift: Double {
        switch self {
        case .orange: return 0
        case .blue: return 195
        case .green: return 110
        case .yellow: return 40
        case .purple: return 255
        case .pink: return 310
        case .teal: return 160
        case .graphite: return 0
        }
    }
    /// Saturation and brightness tweaks after the hue rotation (plain rotation leaves yellow muddy).
    var saturation: Double { self == .yellow ? 1.25 : self == .graphite ? 0 : 1 }
    var brightness: Double { self == .yellow ? 0.10 : self == .graphite ? -0.12 : 0 }
    var title: String {
        switch self {
        case .orange: return L("Orange", "Оранжевый")
        case .blue: return L("Blue", "Синий")
        case .green: return L("Green", "Зелёный")
        case .yellow: return L("Yellow", "Жёлтый")
        case .purple: return L("Purple", "Фиолетовый")
        case .pink: return L("Pink", "Розовый")
        case .teal: return L("Teal", "Бирюзовый")
        case .graphite: return L("Graphite", "Графитовый")
        }
    }

    /// Explicit colour, or the next one in the palette by the profile's position.
    static func of(_ p: Profile, in c: Config) -> ProfileColor {
        if let raw = p.color, let col = ProfileColor(rawValue: raw) { return col }
        let n = c.profiles.firstIndex(where: { $0.id == p.id }) ?? 0
        return allCases[n % allCases.count]
    }
}

private var tintCache: [String: NSImage] = [:]

func tintedClaudeIcon(_ color: ProfileColor, appPath: String) -> NSImage {
    if let hit = tintCache[color.rawValue] { return hit }
    let base = NSWorkspace.shared.icon(forFile: appPath)
    var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    guard color != .orange, let cg = base.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        tintCache[color.rawValue] = base; return base
    }
    let hue = CIFilter(name: "CIHueAdjust")!
    hue.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
    hue.setValue(color.hueShift * .pi / 180, forKey: kCIInputAngleKey)
    let tone = CIFilter(name: "CIColorControls")!
    tone.setValue(hue.outputImage, forKey: kCIInputImageKey)
    tone.setValue(color.saturation, forKey: kCIInputSaturationKey)
    tone.setValue(color.brightness, forKey: kCIInputBrightnessKey)
    guard let out = tone.outputImage, let full = hue.outputImage?.extent,
          let shifted = CIContext().createCGImage(out, from: full) else { return base }
    let image = NSImage(cgImage: shifted, size: NSSize(width: 1024, height: 1024))
    tintCache[color.rawValue] = image
    return image
}

/// .icns bytes for an image, via iconutil.
func icnsData(_ image: NSImage) -> Data? {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let set = dir.appendingPathComponent("icon.iconset"), out = dir.appendingPathComponent("icon.icns")
    defer { try? fm.removeItem(at: dir) }
    do {
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            if size <= 512 { try png.write(to: set.appendingPathComponent("icon_\(size)x\(size).png")) }
            if size >= 32 { try png.write(to: set.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set.path, "-o", out.path]
        try p.run(); p.waitUntilExit()
        return p.terminationStatus == 0 ? fm.contents(atPath: out.path) : nil
    } catch { return nil }
}

/// Icon shown for a profile: an explicit `icon` file if set, otherwise Claude's icon in the profile's colour.
func icon(for p: Profile, _ c: Config) -> NSImage {
    if let path = p.icon.map({ ($0 as NSString).expandingTildeInPath }), FileManager.default.fileExists(atPath: path) {
        return path.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: path) : (NSImage(contentsOfFile: path) ?? NSWorkspace.shared.icon(forFile: c.appPath))
    }
    return tintedClaudeIcon(ProfileColor.of(p, in: c), appPath: c.appPath)
}

/// A resized copy, so shared cached icons are never mutated.
func sized(_ image: NSImage, _ side: CGFloat) -> NSImage {
    let copy = image.copy() as! NSImage; copy.size = NSSize(width: side, height: side); return copy
}

final class ProfileCard: NSButton {
    let profile: Profile
    let running: Bool
    let image32: NSImage
    var isChosen = false { didSet { needsDisplay = true; setAccessibilityValue(isChosen ? L("Selected", "Выбран") : "") } }

    init(_ p: Profile, running: Bool, icon: NSImage) {
        profile = p; self.running = running; image32 = icon
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryChange)
        setAccessibilityLabel(p.name + ", " + (running ? L("running", "запущен") : L("closed", "закрыт")))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 64).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        (isChosen ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill(); box.fill()
        (isChosen ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); box.lineWidth = isChosen ? 1.6 : 1; box.stroke()

        image32.draw(in: NSRect(x: 14, y: 14, width: 36, height: 36), from: .zero, operation: .sourceOver,
                     fraction: running ? 1 : 0.55, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: profile.name, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                           .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            .draw(in: NSRect(x: 62, y: 13, width: bounds.width - 110, height: 20))
        let sub = running ? L("Running on this Mac", "Запущен на этом Маке") : L("Closed — will be opened", "Закрыт — откроется")
        NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: NSPoint(x: 62, y: 35))

        let dot = NSRect(x: bounds.width - 34, y: 24, width: 16, height: 16)
        if isChosen {
            NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: dot).fill()
            let tick = NSBezierPath(); tick.move(to: NSPoint(x: dot.minX + 4, y: dot.midY))
            tick.line(to: NSPoint(x: dot.minX + 7, y: dot.maxY - 5)); tick.line(to: NSPoint(x: dot.maxX - 3.5, y: dot.minY + 5))
            NSColor.white.setStroke(); tick.lineWidth = 1.7; tick.stroke()
        } else { NSColor.tertiaryLabelColor.setStroke(); NSBezierPath(ovalIn: dot).stroke() }

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10); ring.lineWidth = 2; ring.stroke()
        }
    }
}

final class Chooser: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var cards: [ProfileCard] = []
    private var chosen: Profile?
    private var okButton: NSButton!
    private var done: ((Profile?) -> Void)?

    func present(_ c: Config, running: [String: NSRunningApplication], preview: Bool, link: String?, completion: @escaping (Profile?) -> Void) {
        done = completion
        let listHeight = min(CGFloat(c.profiles.count) * 74 - 10, 370)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210 + listHeight),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Claude Profiles"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.delegate = self; window.level = .floating
        let root = NSView(); window.contentView = root

        func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: s); f.font = font; f.textColor = color
            f.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(f); return f
        }
        let title = text(L("Choose a Claude profile", "Выбери профиль Claude"), .systemFont(ofSize: 23, weight: .bold), .labelColor)
        let subtitle = text(L("Send this link to the window where you started it.", "Ссылка уйдёт в окно того профиля, откуда ты её открыл."),
                            .systemFont(ofSize: 13), .secondaryLabelColor)
        if let link { subtitle.toolTip = link }

        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = c.profiles.count > 5
        scroll.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(scroll)
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = stack
        for p in c.profiles {
            let card = ProfileCard(p, running: preview || running[p.id] != nil, icon: icon(for: p, c))
            card.target = self; card.action = #selector(pick(_:))
            stack.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            cards.append(card)
        }

        let cancel = NSButton(title: L("Cancel", "Отмена"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(cancel)
        okButton = NSButton(title: preview ? L("Done", "Готово") : L("Continue", "Продолжить"), target: self, action: #selector(okTapped))
        okButton.bezelStyle = .rounded; okButton.keyEquivalent = "\r"; okButton.isEnabled = false
        okButton.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(okButton)
        let hint = text(preview ? L("Preview only", "Предпросмотр")
                                : L("Other profiles stay as they are", "Другие профили не трогаются"),
                        .systemFont(ofSize: 11), .tertiaryLabelColor)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: listHeight),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            okButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 24),
            okButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            okButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            cancel.centerYAnchor.constraint(equalTo: okButton.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: okButton.leadingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: okButton.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            okButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            root.widthAnchor.constraint(equalToConstant: 460),
        ])
        root.layoutSubtreeIfNeeded()
        window.setContentSize(root.fittingSize)
        scroll.contentView.scroll(to: .zero)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    @objc private func pick(_ sender: ProfileCard) {
        chosen = sender.profile; cards.forEach { $0.isChosen = $0 === sender }; okButton.isEnabled = true
    }
    @objc private func okTapped() { finish(chosen) }
    @objc private func cancelTapped() { finish(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(nil); return false }
    private func finish(_ p: Profile?) { let cb = done; done = nil; window.orderOut(nil); cb?(p) }
}

// MARK: - Menu bar icon

/// Little pixel critter as a template image, drawn from a grid so no image asset is needed.
func critterIcon() -> NSImage {
    let rows = [
        "..#######..",
        "..#.###.#..",
        "###########",
        "..#######..",
        "..#.#.#.#..",
        "..#.#.#.#..",
    ]
    let cell: CGFloat = 2
    let size = NSSize(width: CGFloat(rows[0].count) * cell, height: CGFloat(rows.count) * cell)
    let image = NSImage(size: size, flipped: true) { _ in
        NSColor.black.setFill()
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
            }
        }
        return true
    }
    image.isTemplate = true  // macOS tints it white or black to match the menu bar
    return image
}

// MARK: - Bringing a profile forward

/// Shows a running profile's window the way a Dock click would.
func bringForward(_ app: NSRunningApplication) {
    // 'aevt/rapp' is what a Dock click sends: a hidden or windowless Claude shows its window again.
    let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                        targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
                                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try? reopen.sendEvent(options: [.noReply], timeout: 5)
    app.unhide()
    if #available(macOS 14.0, *), let me = NSApp as NSApplication? { me.yieldActivation(to: app) }
    app.activate(options: [.activateAllWindows])
}

// MARK: - Global shortcuts

struct KeyCombo {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags
    let display: String

    /// Config name of a key ("1", "w", "f5", "space") for a virtual key code, nil if unsupported.
    static func keyName(for code: UInt16) -> String? { keys.first(where: { $0.value == Int(code) })?.key }

    private static let keys: [String: Int] = {
        var k: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "space": kVK_Space,
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (n, code) in fkeys.enumerated() { k["f\(n + 1)"] = code }
        return k
    }()

    /// Parses "ctrl+opt+cmd+1", "⌃⌥⌘1"-style symbols are accepted as separate parts ("⌃+⌥+⌘+1").
    init?(_ text: String) {
        var carbon: UInt32 = 0, flags: NSEvent.ModifierFlags = [], symbols = "", key: String?
        for raw in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch raw {
            case "ctrl", "control", "⌃": carbon |= UInt32(controlKey); flags.insert(.control)
            case "opt", "option", "alt", "⌥": carbon |= UInt32(optionKey); flags.insert(.option)
            case "cmd", "command", "⌘": carbon |= UInt32(cmdKey); flags.insert(.command)
            case "shift", "⇧": carbon |= UInt32(shiftKey); flags.insert(.shift)
            default: if key != nil { return nil }; key = raw
            }
        }
        guard let key, let code = KeyCombo.keys[key] else { return nil }
        let isFunctionKey = key.hasPrefix("f") && key.count > 1
        guard carbon != 0 || isFunctionKey else { return nil }  // a bare letter would hijack typing
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        keyCode = UInt32(code); carbonModifiers = carbon; menuModifiers = flags
        menuKey = isFunctionKey ? "" : (key == "space" ? " " : key)
        display = symbols + (key == "space" ? "Space" : key.uppercased())
    }

    /// The shortcut a profile uses, nil when disabled or unparseable.
    static func `for`(_ p: Profile, position: Int) -> KeyCombo? {
        if let h = p.hotkey { return h.lowercased() == "none" ? nil : KeyCombo(h) }
        return position < 9 ? KeyCombo("ctrl+opt+\(position + 1)") : nil
    }
}

/// Carbon hot keys: system-wide, and unlike an event tap they need no Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandler() {
        guard !installed else { return }; installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func removeAll() { refs.forEach { UnregisterEventHotKey($0) }; refs = []; actions = [:] }

    /// false when another app already holds the same shortcut.
    func register(_ combo: KeyCombo, id: UInt32, action: @escaping () -> Void) -> Bool {
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: OSType(0x434C5052), id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref); actions[id] = action; return true
    }
}

// MARK: - Dock launchers

/// Where a profile's launcher lives: the recorded path, or /Applications/Claude <Name>.app.
func launcherPath(for p: Profile) -> String {
    if let l = p.launcher, !l.isEmpty { return (l as NSString).expandingTildeInPath }
    let safe = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    return "/Applications/Claude \(safe).app"
}

/// Icon bytes for a profile's launcher: its own icon (.app or .icns), else Claude's.
/// Read up front, because the icon may live inside the launcher that is about to be rebuilt.
func launcherIconData(for p: Profile, _ c: Config) -> Data? {
    func bundleIcon(_ app: String) -> Data? {
        guard let b = Bundle(path: app), var name = b.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        return FileManager.default.contents(atPath: app + "/Contents/Resources/" + name)
    }
    if let icon = p.icon.map({ ($0 as NSString).expandingTildeInPath }) {
        if icon.hasSuffix(".app"), let d = bundleIcon(icon) { return d }
        if icon.hasSuffix(".icns"), let d = FileManager.default.contents(atPath: icon) { return d }
    }
    let color = ProfileColor.of(p, in: c)
    return color == .orange ? bundleIcon(c.appPath) : icnsData(tintedClaudeIcon(color, appPath: c.appPath))
}

/// A tiny app that runs `ClaudeProfiles --open <id>`: focuses the profile or starts it.
/// Updated in place, never deleted and recreated: the Dock keeps a bookmark to the bundle itself,
/// and a recreated bundle leaves that bookmark dangling (the tile vanishes or keeps the old picture).
func makeLauncher(id: String, at dest: String, icon: Data?) throws {
    let fm = FileManager.default, contents = dest + "/Contents", resources = contents + "/Resources"
    try fm.createDirectory(atPath: contents + "/MacOS", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: resources, withIntermediateDirectories: true)
    let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let script = "#!/bin/sh\nexec \"\(me)\" --open '\(id.replacingOccurrences(of: "'", with: ""))'\n"
    try script.write(toFile: contents + "/MacOS/launch", atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents + "/MacOS/launch")
    var info: [String: Any] = [
        "CFBundleName": ((dest as NSString).lastPathComponent as NSString).deletingPathExtension,
        "CFBundleIdentifier": helperBundleID + ".launcher." + id,
        "CFBundleExecutable": "launch", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0", "LSUIElement": true,
    ]
    // A fresh icon file name per picture, so macOS cannot serve the previous one from its icon cache.
    for old in (try? fm.contentsOfDirectory(atPath: resources)) ?? [] where old.hasPrefix("AppIcon") {
        try? fm.removeItem(atPath: resources + "/" + old)
    }
    if let icon {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in icon { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        let name = "AppIcon-" + String(hash, radix: 16).prefix(10)
        try icon.write(to: URL(fileURLWithPath: resources + "/" + name + ".icns")); info["CFBundleIconFile"] = name
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
    // Tell Launch Services and Finder that the bundle changed.
    let ls = Process()
    ls.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
    ls.arguments = ["-f", dest]; try? ls.run(); ls.waitUntilExit()
    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest)
    NSWorkspace.shared.noteFileSystemChanged(dest)
}

enum Dock {
    private static let domain = "com.apple.dock" as CFString, key = "persistent-apps" as CFString

    /// Always re-read from disk: a long-running process otherwise keeps a stale cached copy of the Dock's prefs,
    /// and writing that copy back would undo changes made since (including the Dock's own).
    private static func items() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }
    private static func path(of item: [String: Any]) -> String? {
        guard let tile = item["tile-data"] as? [String: Any], let file = tile["file-data"] as? [String: Any],
              let s = file["_CFURLString"] as? String, let u = URL(string: s) else { return nil }
        return norm(u.standardizedFileURL.path)
    }
    /// The Dock stores paths decomposed ("й" as и + breve); compare in one Unicode form or non-Latin names never match.
    private static func norm(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    static func contains(_ app: String) -> Bool { items().contains { path(of: $0) == norm(app) } }

    /// Makes the Dock re-resolve a pinned app by path and re-read its icon.
    static func reload(_ app: String) {
        var list = items(); let target = norm(app); var changed = false
        for i in list.indices where path(of: list[i]) == target {
            if var tile = list[i]["tile-data"] as? [String: Any] { tile.removeValue(forKey: "book"); list[i]["tile-data"] = tile; changed = true }
        }
        if changed { CFPreferencesSetAppValue(key, list as CFPropertyList, domain); CFPreferencesAppSynchronize(domain) }
        refresh()
    }

    /// Restarts the Dock so it re-reads icons.
    static func refresh() {
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); k.arguments = ["Dock"]; try? k.run()
    }

    /// Pins or unpins an app and restarts the Dock so it shows up at once.
    static func set(_ app: String, pinned: Bool) {
        var list = items(), target = norm(app)
        if pinned {
            guard !list.contains(where: { path(of: $0) == target }) else { return }
            list.append(["tile-type": "file-tile", "tile-data": [
                "file-data": ["_CFURLString": URL(fileURLWithPath: target).absoluteString, "_CFURLStringType": 15],
                "file-label": ((target as NSString).lastPathComponent as NSString).deletingPathExtension]])
        } else {
            let before = list.count; list.removeAll { path(of: $0) == target }; guard list.count != before else { return }
        }
        CFPreferencesSetAppValue(key, list as CFPropertyList, domain); CFPreferencesAppSynchronize(domain)
        refresh()
    }
}

// MARK: - Settings window

/// Pill that records a shortcut: click it, press keys. Esc cancels, Delete turns the shortcut off.
final class ShortcutField: NSButton {
    var value: String?            // as stored in profiles.json; nil = default
    var defaultCombo: KeyCombo?   // what nil means for this profile
    var taken = false
    var onRecordStart: (() -> Void)?
    var onChange: ((String?) -> Void)?
    var onRecordEnd: (() -> Void)?
    private var monitor: Any?
    private var recording = false { didSet { refresh() } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; setButtonType(.momentaryPushIn); target = self; action = #selector(toggle)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 130).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let text: String, color: NSColor
        if recording { text = L("Type shortcut…", "Нажми сочетание…"); color = .controlAccentColor }
        else if value?.lowercased() == "none" { text = L("None", "Нет"); color = .tertiaryLabelColor }
        else if let v = value, let c = KeyCombo(v) { text = c.display; color = taken ? .systemRed : .labelColor }
        else if value == nil, let d = defaultCombo { text = d.display; color = taken ? .systemRed : .labelColor }
        else { text = L("None", "Нет"); color = .tertiaryLabelColor }
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: recording ? .regular : .medium)])
        toolTip = taken ? L("Another app already uses this shortcut", "Это сочетание уже занято другим приложением") : nil
    }

    @objc private func toggle() { recording ? stop() : start() }

    private func start() {
        onRecordStart?(); recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .leftMouseDown { if e.window !== self.window || !self.frame.contains(self.convert(e.locationInWindow, from: nil)) { self.stop() }; return e }
            self.handle(e); return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
        if recording { recording = false; onRecordEnd?() }
    }

    private func handle(_ e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Escape: stop(); return
        case kVK_Delete, kVK_ForwardDelete: value = "none"; stop(); onChange?(value); return
        default: break
        }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        guard let key = KeyCombo.keyName(for: e.keyCode) else { NSSound.beep(); return }
        let text = (parts + [key]).joined(separator: "+")
        guard KeyCombo(text) != nil else { NSSound.beep(); return }  // needs a modifier unless it is an F-key
        value = text; taken = false; stop(); onChange?(value)
    }
}

/// Rounded card that follows light/dark appearance.
final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 10; layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private var config: Config!
    private var taken: [String: String] = [:]
    /// Called after every saved change so the helper re-registers shortcuts and rebuilds its menu.
    var onSave: (() -> Void)?
    var currentTaken: (() -> [String: String])?
    var onClose: (() -> Void)?

    func show() {
        guard let c = try? Config.load() else {
            alert(L("Claude Profiles is not configured", "Claude Profiles не настроен"), Config.path); return
        }
        config = c; taken = currentTaken?() ?? [:]
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L("Claude Profiles Settings", "Настройки Claude Profiles"); w.isReleasedWhenClosed = false; w.delegate = self
            window = w
        }
        rebuild()
        window?.center(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)  // do not start with a name selected for editing
    }

    func windowWillClose(_ n: Notification) { window?.makeFirstResponder(nil); onClose?() }

    /// The Dock and profiles.json can change behind the window's back; re-read them whenever it comes forward.
    func windowDidBecomeKey(_ n: Notification) {
        guard !dockBusy, !(window?.firstResponder is NSTextView), let fresh = try? Config.load() else { return }
        config = fresh; taken = currentTaken?() ?? [:]; rebuild()
    }

    /// True for a moment after a Dock change: the restarting Dock rewrites its own prefs, and a second
    /// change in that window would be undone.
    private var dockBusy = false
    private func settleDock(_ sender: NSButton) {
        dockBusy = true; sender.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.dockBusy = false; self?.rebuild() }
    }

    private func save() {
        do { try config.save() } catch { alert(L("Could not save settings", "Не удалось сохранить настройки"), error.localizedDescription) }
        onSave?(); taken = currentTaken?() ?? [:]
    }

    private func rebuild() {
        guard let window else { return }
        let root = NSView(); root.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24); stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let title = NSTextField(labelWithString: L("Profiles", "Профили")); title.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)
        let hint = NSTextField(wrappingLabelWithString: L(
            "Click a shortcut and press new keys. Delete turns it off, Esc cancels.",
            "Нажми на сочетание и введи новое. Delete — отключить, Esc — отмена."))
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint); stack.setCustomSpacing(16, after: hint)

        for (n, p) in config.profiles.enumerated() {
            let row = profileRow(p, position: n); stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        let add = NSButton(title: L("Add Profile…", "Добавить профиль…"), target: self, action: #selector(addProfile))
        add.bezelStyle = .rounded; add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); add.imagePosition = .imageLeading
        stack.addArrangedSubview(add); stack.setCustomSpacing(20, after: add)

        let sep = NSBox(); sep.boxType = .separator; stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true

        let ask = NSButton(checkboxWithTitle: L("Ask where to open links even when one profile is running",
                                                 "Спрашивать, куда открыть ссылку, даже если запущен один профиль"),
                           target: self, action: #selector(toggleAlwaysAsk(_:)))
        ask.state = config.alwaysAsk == true ? .on : .off
        stack.addArrangedSubview(ask)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: 600),
        ])
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        window.setContentSize(root.fittingSize)
    }

    private func profileRow(_ p: Profile, position: Int) -> NSView {
        let card = CardView(); card.wantsLayer = true; card.translatesAutoresizingMaskIntoConstraints = false

        let img = NSButton(image: sized(icon(for: p, config), 36), target: self, action: #selector(pickColor(_:)))
        img.isBordered = false; img.imageScaling = .scaleProportionallyUpOrDown
        img.identifier = NSUserInterfaceItemIdentifier(p.id); img.toolTip = L("Change colour", "Сменить цвет")
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 36).isActive = true; img.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let name = NSTextField(string: p.name); name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.isBordered = false; name.drawsBackground = false; name.focusRingType = .none; name.delegate = self
        name.identifier = NSUserInterfaceItemIdentifier(p.id); name.placeholderString = L("Name", "Название")
        name.toolTip = L("Click to rename", "Нажми, чтобы переименовать")
        let path = NSTextField(labelWithString: p.dataDir.map { ($0 as NSString).abbreviatingWithTildeInPath }
                                                ?? L("Standard Claude profile", "Стандартный профиль Claude"))
        path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor; path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [name, path]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 2
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let field = ShortcutField()
        field.value = p.hotkey; field.defaultCombo = position < 9 ? KeyCombo("ctrl+opt+\(position + 1)") : nil
        field.taken = taken[p.id] != nil; field.refresh()
        field.onRecordStart = { HotKeys.shared.removeAll() }   // so the old keys do not fire while recording
        field.onRecordEnd = { [weak self] in self?.onSave?() }
        field.onChange = { [weak self] v in self?.update(p.id) { $0.hotkey = v }; self?.save() }

        let inDock = Dock.contains(launcherPath(for: p))
        let dock = NSButton(title: inDock ? L("In Dock", "В Доке") : L("Add to Dock", "В Док"), target: self, action: #selector(toggleDock(_:)))
        dock.bezelStyle = .rounded; dock.controlSize = .small; dock.font = .systemFont(ofSize: 11)
        dock.image = NSImage(systemSymbolName: inDock ? "checkmark" : "dock.rectangle", accessibilityDescription: nil)
        dock.imagePosition = .imageLeading; dock.identifier = NSUserInterfaceItemIdentifier(p.id)
        dock.toolTip = inDock ? L("Click to remove its icon from the Dock", "Нажми, чтобы убрать значок из Дока")
                              : L("Pin an icon that opens this profile", "Закрепить в Доке значок, который открывает этот профиль")
        var views: [NSView] = [img, texts, field, dock]
        if p.dataDir != nil {
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove", "Удалить"))!,
                                  target: self, action: #selector(removeProfile(_:)))
            remove.isBordered = false; remove.contentTintColor = .secondaryLabelColor
            remove.identifier = NSUserInterfaceItemIdentifier(p.id); remove.toolTip = L("Remove profile", "Удалить профиль")
            remove.translatesAutoresizingMaskIntoConstraints = false
            remove.widthAnchor.constraint(equalToConstant: 20).isActive = true
            views.append(remove)
        } else {
            // The standard profile cannot be removed; keep its shortcut aligned with the others.
            let gap = NSView(); gap.translatesAutoresizingMaskIntoConstraints = false
            gap.widthAnchor.constraint(equalToConstant: 20).isActive = true
            views.append(gap)
        }
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 12; row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    private func update(_ id: String, _ change: (inout Profile) -> Void) {
        guard let i = config.profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&config.profiles[i])
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField, let id = f.identifier?.rawValue else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { f.stringValue = config.profiles.first(where: { $0.id == id })?.name ?? ""; return }
        if config.profiles.first(where: { $0.id == id })?.name != name { update(id) { $0.name = name }; save() }
    }

    @objc private func toggleAlwaysAsk(_ sender: NSButton) { config.alwaysAsk = sender.state == .on ? true : nil; save() }

    @objc private func addProfile() {
        let a = NSAlert(); a.messageText = L("New profile", "Новый профиль")
        a.informativeText = L("It gets its own Claude account, chats and settings.", "У него будут свой аккаунт Claude, чаты и настройки.")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); input.placeholderString = L("Name, e.g. Side project", "Название, например «Пет-проект»")
        a.accessoryView = input; a.addButton(withTitle: L("Add", "Добавить")); a.addButton(withTitle: L("Cancel", "Отмена"))
        a.window.initialFirstResponder = input
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { return }
        let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name).applyingTransform(.stripDiacritics, reverse: false) ?? name
        var slug = latin.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        if slug.isEmpty { slug = "profile" }
        var id = slug, n = 2
        while config.profiles.contains(where: { $0.id == id }) { id = "\(slug)-\(n)"; n += 1 }
        let folder = "~/Library/Application Support/Claude-" + id
        config.profiles.append(Profile(id: id, name: name, userDataDir: folder, icon: nil, hotkey: nil))
        save(); rebuild()
    }

    @objc private func pickColor(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let p = config.profiles.first(where: { $0.id == id }) else { return }
        let current = ProfileColor.of(p, in: config)
        let menu = NSMenu()
        for col in ProfileColor.allCases {
            let item = NSMenuItem(title: col.title, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = [id, col.rawValue]; item.state = col == current && p.icon == nil ? .on : .off
            item.image = sized(tintedClaudeIcon(col, appPath: config.appPath), 18)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func colorChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let id = pair[0]
        update(id) { $0.color = pair[1]; $0.icon = nil }
        save()
        // Repaint the profile's Dock launcher too.
        if let p = config.profiles.first(where: { $0.id == id }), let l = p.launcher {
            let app = (l as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: app) {
                try? makeLauncher(id: id, at: app, icon: launcherIconData(for: p, config))
                if Dock.contains(app) { Dock.reload(app) }
            }
        }
        rebuild()
    }

    @objc private func toggleDock(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let p = config.profiles.first(where: { $0.id == id }) else { return }
        guard !dockBusy else { return }
        let app = launcherPath(for: p)
        if Dock.contains(app) { Dock.set(app, pinned: false); settleDock(sender); return }
        do {
            let icon = launcherIconData(for: p, config)
            try makeLauncher(id: p.id, at: app, icon: icon)
            update(id) { $0.launcher = app }
            save(); Dock.set(app, pinned: true); settleDock(sender)
        } catch {
            alert(L("Could not create the Dock icon", "Не получилось создать значок для Дока"), error.localizedDescription)
            rebuild()
        }
    }

    @objc private func removeProfile(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let p = config.profiles.first(where: { $0.id == id }) else { return }
        let a = NSAlert(); a.messageText = L("Remove “\(p.name)”?", "Удалить профиль «\(p.name)»?")
        a.informativeText = L("Its Dock icon goes to the Trash. The data folder stays on disk, so the account and chats are not lost.",
                              "Его значок из Дока уйдёт в Корзину. Папка с данными останется на диске: аккаунт и чаты не пропадут.")
        a.addButton(withTitle: L("Remove", "Удалить")); a.addButton(withTitle: L("Cancel", "Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let l = p.launcher, FileManager.default.fileExists(atPath: (l as NSString).expandingTildeInPath) {
            let app = (l as NSString).expandingTildeInPath
            Dock.set(app, pinned: false); try? FileManager.default.trashItem(at: URL(fileURLWithPath: app), resultingItemURL: nil)
        }
        config.profiles.removeAll { $0.id == id }; save(); rebuild()
    }
}

// MARK: - Helper app

final class Helper: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var chooser: Chooser?
    private var queue: [String] = []
    private var ready = false
    private var timer: Timer?
    private let previewOnly = CommandLine.arguments.contains("--preview")
    private let settingsOnly = CommandLine.arguments.contains("--settings")
    private lazy var settings: SettingsWindow = {
        let s = SettingsWindow()
        s.onSave = { [weak self] in if self?.settingsOnly == false { self?.reloadConfig() } }
        s.currentTaken = { [weak self] in self?.takenShortcuts ?? [:] }
        s.onClose = { [weak self] in if self?.settingsOnly == true { NSApp.terminate(nil) } }
        return s
    }()

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: kGURL, andEventID: kGURL)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if previewOnly { ready = true; showPreview(); return }
        if settingsOnly { settings.show(); return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = critterIcon()
        item.button?.setAccessibilityLabel("Claude Profiles")
        statusItem = item
        reloadConfig(); claimHandler(); ready = true; drain()
        // Claude Desktop re-registers itself for claude:// on launch; take the scheme back.
        // The same tick picks up edits to profiles.json.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.claimHandler(); self?.reloadIfConfigChanged()
        }
    }

    private var configStamp: Date?
    /// Shortcuts that could not be registered because another app holds them, by profile id.
    private var takenShortcuts: [String: String] = [:]

    private func reloadIfConfigChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Config.path))?[.modificationDate] as? Date
        if stamp != configStamp { reloadConfig() }
    }

    private func reloadConfig() {
        configStamp = (try? FileManager.default.attributesOfItem(atPath: Config.path))?[.modificationDate] as? Date
        HotKeys.shared.removeAll(); takenShortcuts = [:]
        if let c = try? Config.load() {
            for (n, p) in c.profiles.enumerated() {
                guard let combo = KeyCombo.for(p, position: n) else { continue }
                let id = p.id
                if !HotKeys.shared.register(combo, id: UInt32(n + 1), action: { [weak self] in self?.summon(id) }) {
                    takenShortcuts[p.id] = combo.display
                }
            }
        }
        buildMenu()
    }

    /// Shortcut / menu action: start a closed profile, bring a background one forward, hide a frontmost one.
    func summon(_ id: String) {
        guard let c = try? Config.load(), let p = c.profiles.first(where: { $0.id == id }) else { return }
        if let app = runningProfiles(c)[id] {
            if app.isActive { app.hide() } else { bringForward(app) }
        } else { try? launch(p, c) }
    }

    func applicationWillTerminate(_ n: Notification) {
        if !previewOnly && currentHandler().lowercased() == helperBundleID { setHandler(claudeBundleID) }
    }

    private func claimHandler() { if currentHandler().lowercased() != helperBundleID { setHandler(helperBundleID) } }

    func buildMenu() {
        let menu = NSMenu()
        let head = menu.addItem(withTitle: "Claude Profiles", action: nil, keyEquivalent: ""); head.isEnabled = false
        menu.addItem(.separator())
        if let c = try? Config.load() {
            let running = runningProfiles(c)
            for (n, p) in c.profiles.enumerated() {
                let item = menu.addItem(withTitle: p.name, action: #selector(openProfile(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = p.id
                // A green dot marks a running profile, like the Dock's running indicator.
                item.onStateImage = runningDot; item.offStateImage = nil
                item.state = running[p.id] != nil ? .on : .off
                item.image = sized(icon(for: p, c), 18)
                if let taken = takenShortcuts[p.id] {
                    item.title = p.name + "  " + L("(\(taken) is taken)", "(\(taken) занято)")
                } else if let combo = KeyCombo.for(p, position: n), !combo.menuKey.isEmpty {
                    item.keyEquivalent = combo.menuKey; item.keyEquivalentModifierMask = combo.menuModifiers
                }
            }
        } else {
            let bad = menu.addItem(withTitle: L("profiles.json is missing or invalid", "profiles.json не найден или битый"), action: nil, keyEquivalent: "")
            bad.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Settings…", "Настройки…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit", "Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc private func openProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        summon(id)
    }

    private lazy var runningDot: NSImage = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill(); return true
        }
        image.isTemplate = false
        return image
    }()

    @objc private func openSettings() { settings.show() }

    @objc func showPreview() {
        guard chooser == nil, let c = try? Config.load() else { if previewOnly { NSApp.terminate(nil) }; return }
        let ch = Chooser(); chooser = ch
        ch.present(c, running: runningProfiles(c), preview: true, link: nil) { [weak self] _ in
            self?.chooser = nil
            if self?.previewOnly == true { NSApp.terminate(nil) } else { self?.drain() }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, isAcceptable(raw), queue.count < 10 else { return }
        queue.append(raw); drain()
    }

    private func drain() {
        guard ready, chooser == nil, !queue.isEmpty else { return }
        let raw = queue.removeFirst()
        guard let c = try? Config.load() else {
            alert(L("Claude Profiles is not configured", "Claude Profiles не настроен"), Config.path); drain(); return
        }
        let running = runningProfiles(c)
        // One profile open (or only one configured): no reason to ask.
        if c.alwaysAsk != true, running.count == 1, let id = running.keys.first, let p = c.profiles.first(where: { $0.id == id }) {
            route(raw, to: p, c); drain(); return
        }
        if c.profiles.count == 1 { route(raw, to: c.profiles[0], c); drain(); return }
        let ch = Chooser(); chooser = ch
        ch.present(c, running: running, preview: false, link: raw) { [weak self] p in
            self?.chooser = nil
            if let p { self?.route(raw, to: p, c) }
            self?.drain()
        }
    }

    private func route(_ raw: String, to p: Profile, _ c: Config) {
        if let app = runningProfiles(c)[p.id] { send(raw, app, p); return }
        do { try launch(p, c) } catch {
            alert(L("Could not open \(p.name)", "Не удалось открыть \(p.name)"), c.appPath); return
        }
        // Wait for the new instance to appear, then give Electron a moment to install its open-url handler.
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            tries += 1
            if let app = runningProfiles(c)[p.id], app.isFinishedLaunching {
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.send(raw, app, p) }
            } else if tries > 60 {
                t.invalidate()
                alert(L("\(p.name) did not start", "\(p.name) не запустился"),
                      L("The link was not sent to another profile.", "Ссылка не отправлена в другой профиль."))
            }
        }
    }

    private func send(_ raw: String, _ app: NSRunningApplication, _ p: Profile) {
        do { try deliver(raw, to: app); app.activate(options: [.activateAllWindows]) } catch {
            alert(L("Could not reach \(p.name)", "Не получилось достучаться до \(p.name)"),
                  L("macOS refused to deliver the link (\(error.localizedDescription)). Check System Settings → Privacy & Security → Automation.",
                    "macOS не дал передать ссылку (\(error.localizedDescription)). Проверь «Системные настройки → Конфиденциальность и безопасность → Автоматизация»."))
        }
    }
}

extension Helper: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {}
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh the running markers each time the menu opens.
        guard let c = try? Config.load() else { return }
        let running = runningProfiles(c)
        for item in menu.items { if let id = item.representedObject as? String { item.state = running[id] != nil ? .on : .off } }
    }
}

// MARK: - Command line

let args = CommandLine.arguments
if args.contains("--status") {
    print("claude:// handler: \(currentHandler())")
    guard let c = try? Config.load() else { print("No valid config at \(Config.path)"); exit(1) }
    let running = runningProfiles(c)
    for p in c.profiles {
        print("\(p.id)\t\(p.name)\t\(running[p.id].map { "running (pid \($0.processIdentifier))" } ?? "closed")\t\(p.dataDir ?? "default")")
    }
    exit(0)
}
if args.contains("--restore-handler") { exit(setHandler(claudeBundleID) == 0 ? 0 : 1) }
if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
    // --open <profile-id>: focus the profile if it is running, otherwise start it. Used by Dock launchers.
    guard let c = try? Config.load(), let p = c.profiles.first(where: { $0.id == args[i + 1] }) else {
        print("unknown profile \(args[i + 1])"); exit(1)
    }
    if let app = runningProfiles(c)[p.id] { bringForward(app); exit(0) }
    do { try launch(p, c); exit(0) } catch { print(error); exit(1) }
}
if let i = args.firstIndex(of: "--make-launcher"), i + 2 < args.count {
    // --make-launcher <profile-id> <path/Name.app> [icon.icns]: a Dock-friendly app that runs --open.
    let id = args[i + 1], dest = (args[i + 2] as NSString).expandingTildeInPath
    guard var c = try? Config.load(), let n = c.profiles.firstIndex(where: { $0.id == id }) else { print("unknown profile \(id)"); exit(1) }
    let icon = i + 3 < args.count ? FileManager.default.contents(atPath: (args[i + 3] as NSString).expandingTildeInPath)
                                  : launcherIconData(for: c.profiles[n], c)
    do {
        try makeLauncher(id: id, at: dest, icon: icon)
        c.profiles[n].launcher = dest; try c.save()
        if Dock.contains(dest) { Dock.reload(dest) }
        print("Launcher for \(c.profiles[n].name): \(dest)"); exit(0)
    } catch { print(error); exit(1) }
}
if let i = args.firstIndex(of: "--deliver"), i + 2 < args.count {
    // --deliver <profile-id> <url>: testing aid, sends a link without the chooser.
    guard let c = try? Config.load(), let p = c.profiles.first(where: { $0.id == args[i + 1] }),
          let app = runningProfiles(c)[p.id], isAcceptable(args[i + 2]) else { print("profile not running or bad url"); exit(1) }
    do { try deliver(args[i + 2], to: app); exit(0) } catch { print(error); exit(1) }
}

// Only one resident helper at a time; a second launch (e.g. via a link) just exits after handing off.
let lock = open(Config.directory + "/helper.lock", O_CREAT | O_RDWR, 0o600)
if !args.contains("--preview") && !args.contains("--settings") {
    var held = false
    for _ in 0..<30 { if lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 { held = true; break }; usleep(100_000) }
    if !held { exit(0) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = Helper()
app.delegate = helper
app.run()
