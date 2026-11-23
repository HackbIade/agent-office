// Agent Office: floating pixel-art office that shows what Claude Code agents are doing.
// Reads $AGENT_OFFICE_DIR/events.jsonl (default ~/agent-office), written by hook.sh.
// Draws only while something moves.
import Cocoa

let baseDir = ProcessInfo.processInfo.environment["AGENT_OFFICE_DIR"] ?? (NSHomeDirectory() + "/agent-office")

// MARK: - Model

struct Ev: Decodable {
    let t: Double; let ev: String; let sid: String; let proj: String
    let aid: String; let atype: String; let tool: String; let bg: Bool; let ntype: String; let d: String
}

enum Act { case idle, think, type, read, write, delegate, talk, browse, wait, done }

final class Agent {
    let id: String; var name: String; var kind: String
    var act: Act = .think; var detail = ""; var last: Double; var born: Double
    var leaving: Double? = nil; var slot = -1
    init(id: String, name: String, kind: String, now: Double) { self.id = id; self.name = name; self.kind = kind; last = now; born = now }
}

func label(forKind k: String) -> String {
    switch k {
    case "lead": return "Líder"
    case "ac-verifier": return "Verificador"
    case "Explore": return "Explorador"
    case "general-purpose", "claude": return "Ayudante"
    case "fork": return "Clon"
    case "Plan": return "Arquitecto"
    case "web-fetch": return "Lector web"
    case "": return "Subagente"
    default: return k
    }
}

func act(forTool t: String) -> Act {
    switch t {
    case "Read", "Grep", "Glob": return .read
    case "Edit", "Write", "NotebookEdit", "MultiEdit": return .write
    case "Agent", "Task", "Workflow": return .delegate
    case "AskUserQuestion": return .wait
    case "WebFetch", "WebSearch": return .browse
    default:
        let l = t.lowercased()
        if l.contains("slack") || l.contains("sendmessage") || l.contains("gmail") || l.contains("mail") { return .talk }
        if l.contains("chrome") || l.contains("browser") || l.contains("figma") || l.contains("linear") { return .browse }
        if l.contains("artifact") { return .write }
        return .type
    }
}

final class Office {
    var agents: [String: Agent] = [:]
    var pendingDesc: [String: String] = [:]
    var watchers: [String] = []
    var docker = false
    let slots = 6

    func session(_ e: Ev) -> Agent {
        let key = "s:" + e.sid
        if let a = agents[key] { if a.leaving != nil { a.leaving = nil }; return a }
        let a = Agent(id: key, name: "Líder · " + e.proj, kind: "lead", now: e.t)
        agents[key] = a; assign(a); return a
    }

    func sub(_ e: Ev) -> Agent {
        let key = "a:" + e.aid
        if let a = agents[key] { return a }
        let a = Agent(id: key, name: label(forKind: e.atype), kind: e.atype, now: e.t)
        agents[key] = a; assign(a); return a
    }

    func assign(_ a: Agent) {
        let used = Set(agents.values.map { $0.slot })
        // The lead of a session prefers the first desks.
        for s in 0..<slots where !used.contains(s) { a.slot = s; return }
        a.slot = -1
    }

    func handle(_ e: Ev) {
        let target: Agent = e.aid.isEmpty ? session(e) : sub(e)
        target.last = e.t
        switch e.ev {
        case "SessionStart": target.act = .idle; target.detail = "llegó a la oficina"
        case "SessionEnd": target.leaving = e.t; target.act = .done
        case "UserPromptSubmit": target.act = .think; target.detail = "pensando…"
        case "PreToolUse":
            target.act = act(forTool: e.tool)
            target.detail = e.d.isEmpty ? e.tool : (e.d.hasPrefix("/") ? (e.d as NSString).lastPathComponent : e.d)
            if e.tool == "Agent" || e.tool == "Task" { pendingDesc[e.sid] = e.d }
        case "PostToolUse", "PostToolUseFailure":
            if target.act != .wait { target.act = .think }
        case "SubagentStart":
            target.act = .think
            if let d = pendingDesc.removeValue(forKey: e.sid) { target.detail = d }
        case "SubagentStop": target.act = .done; target.detail = "terminó"; target.leaving = e.t
        case "Notification":
            target.act = .wait
            target.detail = e.ntype == "idle_prompt" ? "esperando tu mensaje" : "necesita tu permiso"
        case "Stop": if e.aid.isEmpty { target.act = .idle; target.detail = "listo, esperando" }
        case "PreCompact": target.act = .think; target.detail = "ordenando su memoria"
        default: break
        }
    }

    func prune(now: Double) {
        for (k, a) in agents {
            if let l = a.leaving, now - l > 3 { agents.removeValue(forKey: k); continue }
            let quiet = now - a.last
            if a.kind == "lead" ? quiet > 1800 : quiet > 1200 { agents.removeValue(forKey: k) }
        }
        for a in agents.values where a.slot < 0 { assign(a) }
    }

    var busy: Bool {
        agents.values.contains { $0.act != .idle } || !watchers.isEmpty || docker
    }
}

// MARK: - Event feed

final class Feed {
    let path = baseDir + "/events.jsonl"
    var offset: UInt64 = 0
    let dec = JSONDecoder()

    func read(into o: Office, replay: Bool) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        if size == offset { return false }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        guard let lastNL = data.lastIndex(of: 10) else { return false }
        offset += UInt64(lastNL + 1)
        let cutoff = Date().timeIntervalSince1970 - 1800
        for line in data[..<lastNL].split(separator: 10) {
            guard let e = try? dec.decode(Ev.self, from: Data(line)) else { continue }
            if replay && e.t < cutoff { continue }
            o.handle(e)
        }
        if replay { for a in o.agents.values { a.born = 0 } }
        return true
    }
}

// MARK: - Drawing

func c(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let kindColor: [String: UInt32] = [
    "lead": 0xE07A4F, "ac-verifier": 0x4FB477, "Explore": 0x4F8FE0, "general-purpose": 0x9B6FD6,
    "fork": 0xE0C04F, "Plan": 0x4FC6C6, "web-fetch": 0xD65F9B, "watcher": 0x8A93A6,
]

final class OfficeView: NSView {
    let office: Office
    var P: CGFloat = 3
    var frameNo = 0
    let W = 150, H = 104
    static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm"; return d }()
    init(office: Office) { self.office = office; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }

    func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ col: UInt32) {
        c(col).setFill(); NSRect(x: CGFloat(x) * P, y: CGFloat(y) * P, width: CGFloat(w) * P, height: CGFloat(h) * P).fill()
    }

    func text(_ s: String, _ x: Int, _ y: Int, size: CGFloat, col: UInt32, bold: Bool = false, maxW: Int = 44) {
        let f = NSFont.monospacedSystemFont(ofSize: size * P / 3, weight: bold ? .bold : .regular)
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c(col), .paragraphStyle: p]
        (s as NSString).draw(in: NSRect(x: CGFloat(x) * P, y: CGFloat(y) * P, width: CGFloat(maxW) * P, height: size * P / 3 + 4), withAttributes: a)
    }

    override func draw(_ dirty: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        let f = frameNo
        // Wall and floor.
        px(0, 0, W, 30, 0x2E3247); px(0, 28, W, 2, 0x22253A)
        for ty in 0..<13 { for tx in 0..<25 { px(tx * 6, 30 + ty * 6, 6, 6, (tx + ty) % 2 == 0 ? 0x3A3F5C : 0x353A55) } }
        // Window with the real sky.
        let hour = Calendar.current.component(.hour, from: Date())
        let sky: UInt32 = (6..<17).contains(hour) ? 0x7EC8F0 : (17..<19).contains(hour) ? 0xF4A261 : 0x1D2440
        px(5, 4, 30, 18, 0x5A5F7A); px(6, 5, 28, 16, sky); px(19, 5, 2, 16, 0x5A5F7A); px(6, 12, 28, 2, 0x5A5F7A)
        if sky == 0x1D2440 { px(10, 8, 1, 1, 0xFFFFFF); px(27, 16, 1, 1, 0xFFFFFF); px(24, 7, 1, 1, 0xFFF3B0) }
        else { px(8 + (f / 40) % 10, 7, 5, 2, 0xFFFFFF); px(23, 16 - (f / 60) % 2, 6, 2, 0xFFFFFF) }
        // Title and clock.
        let active = office.agents.values.filter { $0.act != .idle && $0.leaving == nil }.count
        text("OFICINA DE AGENTES", 40, 5, size: 10, col: 0xF2E9DC, bold: true, maxW: 70)
        text("\(office.agents.count) en la oficina · \(active) trabajando", 40, 12, size: 7.5, col: 0xA9AEC4, maxW: 70)
                px(114, 5, 18, 8, 0x1B1D2B); text(OfficeView.df.string(from: Date()), 113, 6, size: 8, col: 0x7CF29A, bold: true, maxW: 20)
        // Plant.
        px(138, 20, 6, 8, 0x8B5E3C); px(136, 12, 3, 6, 0x3E9E5B); px(140, 9, 3, 9, 0x4FB477); px(143, 13, 3, 6, 0x3E9E5B)

        drawServer(f)
        let desks = [(8, 50), (48, 50), (88, 50), (8, 84), (48, 84), (88, 84)]
        let bySlot = Dictionary(office.agents.values.filter { $0.slot >= 0 }.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
        for (i, d) in desks.enumerated() { drawDesk(d.0, d.1, bySlot[i], f) }
        let lobby = office.agents.values.filter { $0.slot < 0 }.count
        if lobby > 0 { text("+\(lobby) en el lobby", 88, 99, size: 7, col: 0xA9AEC4, maxW: 36) }
        drawWatchers(f)
    }

    func drawServer(_ f: Int) {
        px(130, 33, 16, 24, 0x1B1D2B); px(131, 34, 14, 22, 0x2A2D40)
        for r in 0..<4 {
            px(132, 35 + r * 5, 12, 4, 0x15161F)
            let on = office.docker
            px(133, 36 + r * 5, 1, 1, on ? ((f / (2 + r)) % 2 == 0 ? 0x7CF29A : 0x2E5E3C) : 0x3A2020)
            px(135, 36 + r * 5, 1, 1, on ? ((f / (3 + r)) % 3 == 0 ? 0xF2C14E : 0x5A4A20) : 0x3A2020)
        }
        text(office.docker ? "docker ON" : "docker off", 126, 58, size: 7, col: office.docker ? 0x7CF29A : 0x6B7088, maxW: 24)
    }

    func drawWatchers(_ f: Int) {
        for (i, w) in office.watchers.prefix(2).enumerated() {
            let x = 132, y = 66 + i * 18
            robot(x, y, color: kindColor["watcher"]!, act: .read, f: f + i * 7, legs: true)
            // Binoculars.
            px(x + 3, y + 4, 2, 2, 0x1B1D2B); px(x + 7, y + 4, 2, 2, 0x1B1D2B)
            text("vigía " + w, 124, y + 15, size: 6.5, col: 0xC9CEDF, maxW: 28)
        }
        if office.watchers.count > 2 { text("+\(office.watchers.count - 2)", 140, 100, size: 7, col: 0xA9AEC4, maxW: 10) }
    }

    func drawDesk(_ x: Int, _ y: Int, _ a: Agent?, _ f: Int) {
        let now = Date().timeIntervalSince1970
        if let a = a {
            var dy = 0
            if a.born > 0, now - a.born < 0.8 { dy = Int((1 - (now - a.born) / 0.8) * 14) }
            if let l = a.leaving { dy = Int(min(1, (now - l) / 2.5) * 14) }
            robot(x + 7, y - 15 + dy, color: kindColor[a.kind] ?? 0xB0B6C8, act: a.act, f: f + a.slot * 5, legs: false, lead: a.kind == "lead")
            bubble(x + 7, y - 15 + dy, a.act, f)
        }
        // Desk with monitor.
        px(x + 22, y - 9, 12, 8, 0x1B1D2B); monitor(x + 23, y - 8, a?.act, f); px(x + 27, y - 1, 2, 1, 0x1B1D2B)
        px(x, y, 36, 3, 0xA0714F); px(x, y + 3, 36, 3, 0x7A5238); px(x + 2, y + 6, 2, 2, 0x5A3C28); px(x + 32, y + 6, 2, 2, 0x5A3C28)
        if a?.act == .idle { px(x + 5, y - 2, 3, 2, 0xF2E9DC); if (f / 4) % 2 == 0 { px(x + 6, y - 4, 1, 1, 0xC9CEDF) } else { px(x + 6, y - 5, 1, 1, 0xC9CEDF) } }
        if let a = a {
            text(a.name, x - 4, y + 8, size: 8, col: kindColor[a.kind] ?? 0xF2E9DC, bold: true)
            text(a.detail, x - 4, y + 12, size: 6.5, col: 0xA9AEC4)
        } else {
            text("libre", x - 4, y + 8, size: 7, col: 0x50556E)
        }
    }

    func monitor(_ x: Int, _ y: Int, _ a: Act?, _ f: Int) {
        guard let a = a else { px(x, y, 10, 6, 0x10111A); return }
        switch a {
        case .type, .delegate:
            px(x, y, 10, 6, 0x0F2A1A)
            for r in 0..<3 { let w = 3 + ((f + r * 3) * 7) % 6; px(x + 1, y + 1 + r * 2, w, 1, 0x7CF29A) }
        case .read: px(x, y, 10, 6, 0xF2E9DC); for r in 0..<3 { px(x + 1, y + 1 + r * 2, 8 - (r + f / 6) % 3, 1, 0x8A93A6) }
        case .write: px(x, y, 10, 6, 0xF2E9DC); px(x + 1, y + 1, 6, 1, 0x4F8FE0); px(x + 1, y + 3, (f / 2) % 8 + 1, 1, 0xE07A4F)
        case .browse: px(x, y, 10, 6, 0x2B4C7E); px(x + 1, y + 1, 8, 1, 0x7EC8F0); px(x + 1, y + 3, 4, 2, 0xF2C14E)
        case .talk: px(x, y, 10, 6, 0x3B1E4A); px(x + 1, y + 1 + (f / 3) % 3, 6, 1, 0xE0A3F2)
        case .wait: px(x, y, 10, 6, (f / 4) % 2 == 0 ? 0x5A4A20 : 0x3A3015); px(x + 4, y + 1, 2, 3, 0xF2C14E); px(x + 4, y + 5, 2, 1, 0xF2C14E)
        case .think: px(x, y, 10, 6, 0x1B2440); px(x + 2 + (f / 3) % 6, y + 2, 2, 2, 0x7EC8F0)
        case .done: px(x, y, 10, 6, 0x0F2A1A); px(x + 3, y + 3, 1, 1, 0x7CF29A); px(x + 4, y + 4, 1, 1, 0x7CF29A); px(x + 5, y + 3, 1, 1, 0x7CF29A); px(x + 6, y + 2, 1, 1, 0x7CF29A)
        case .idle: px(x, y, 10, 6, 0x10111A); px(x + (f / 8) % 9, y + (f / 5) % 5, 1, 1, 0x4F8FE0)
        }
    }

    /// Original boxy robot: antenna, screen face, square body.
    func robot(_ x: Int, _ y: Int, color: UInt32, act: Act, f: Int, legs: Bool, lead: Bool = false) {
        let dark: UInt32 = 0x1B1D2B
        let bob = (act == .type || act == .write || act == .delegate) ? (f / 2) % 2 : 0
        px(x + 5, y, 1, 2, dark); px(x + 4, y - 1, 3, 1, (f / 6) % 2 == 0 && act != .idle ? 0xF2C14E : 0x8A93A6)
        if lead { px(x + 1, y + 1, 10, 1, 0xF2C14E) }
        px(x, y + 2, 12, 7, color); px(x + 1, y + 3, 10, 5, dark)
        // Eyes by mood.
        let blink = f % 37 == 0
        switch act {
        case .idle: px(x + 3, y + 5, 2, 1, 0x7EC8F0); px(x + 7, y + 5, 2, 1, 0x7EC8F0)
        case .done: px(x + 3, y + 4, 1, 1, 0x7CF29A); px(x + 4, y + 5, 1, 1, 0x7CF29A); px(x + 7, y + 5, 1, 1, 0x7CF29A); px(x + 8, y + 4, 1, 1, 0x7CF29A)
        case .wait: px(x + 3, y + 4, 2, 3, 0xF2C14E); px(x + 7, y + 4, 2, 3, 0xF2C14E)
        default:
            let look = (act == .read || act == .browse) ? (f / 8) % 2 : 0
            if blink { px(x + 3 + look, y + 5, 2, 1, 0x7EC8F0); px(x + 7 + look, y + 5, 2, 1, 0x7EC8F0) }
            else { px(x + 3 + look, y + 4, 2, 2, 0x7EC8F0); px(x + 7 + look, y + 4, 2, 2, 0x7EC8F0) }
        }
        px(x + 2, y + 9, 8, 5, color); px(x + 4, y + 10, 4, 2, dark)
        px(x + 1, y + 10 + bob, 1, 3, color); px(x + 10, y + 11 - bob, 1, 3, color)
        if legs { px(x + 3, y + 14, 2, 2, dark); px(x + 7, y + 14, 2, 2, dark) }
    }

    func bubble(_ x: Int, _ y: Int, _ a: Act, _ f: Int) {
        let bx = x + 12, by = y - 6
        func box(_ w: Int) { px(bx, by, w, 6, 0xF2E9DC); px(bx, by + 6, 2, 1, 0xF2E9DC) }
        switch a {
        case .think: box(9); for i in 0..<3 where (f / 3) % 4 > i { px(bx + 1 + i * 3, by + 3, 1, 1, 0x2E3247) }
        case .wait: if (f / 4) % 2 == 0 { box(5); px(bx + 2, by + 1, 1, 3, 0xD64F4F); px(bx + 2, by + 5, 1, 1, 0xD64F4F) }
        case .talk: box(9); px(bx + 1, by + 2, 7, 1, 0x9B6FD6); px(bx + 1, by + 4, 4 + (f / 3) % 3, 1, 0x9B6FD6)
        case .delegate: box(7); px(bx + 1, by + 2, 2, 2, 0x4FB477); px(bx + 4, by + 2, 2, 2, 0x4F8FE0); px(bx + 3, by + 3, 1, 1, 0x2E3247)
        case .done: box(6); px(bx + 1, by + 3, 1, 1, 0x4FB477); px(bx + 2, by + 4, 1, 1, 0x4FB477); px(bx + 3, by + 3, 1, 1, 0x4FB477); px(bx + 4, by + 2, 1, 1, 0x4FB477)
        default: break
        }
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let office = Office(); let feed = Feed()
    var panel: NSPanel!; var view: OfficeView!
    var timer: Timer?; var fast = false; var tick = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = feed.read(into: office, replay: true)
        view = OfficeView(office: office)
        let scale = CGFloat(UserDefaults.standard.double(forKey: "scale").nonZero ?? 3)
        view.P = scale
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CGFloat(view.W) * scale, height: CGFloat(view.H) * scale),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        view.wantsLayer = true; view.layer?.cornerRadius = 10; view.layer?.masksToBounds = true
        panel.contentView = view
        if !panel.setFrameUsingName("AgentOffice") {
            if let s = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: s.maxX - panel.frame.width - 20, y: s.minY + 20)) }
        }
        panel.setFrameAutosaveName("AgentOffice")
        let menu = NSMenu()
        for (t, s) in [("Pequeño", 2.0), ("Mediano", 3.0), ("Grande", 4.0)] {
            let it = NSMenuItem(title: t, action: #selector(resize(_:)), keyEquivalent: ""); it.target = self; it.tag = Int(s); menu.addItem(it)
        }
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Cerrar la oficina", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(q)
        view.menu = menu
        panel.orderFrontRegardless()
        pollSystem()
        schedule(fast: true)
    }

    @objc func resize(_ s: NSMenuItem) {
        let p = CGFloat(s.tag); view.P = p; UserDefaults.standard.set(Double(p), forKey: "scale")
        var fr = panel.frame; let top = fr.maxY
        fr.size = NSSize(width: CGFloat(view.W) * p, height: CGFloat(view.H) * p); fr.origin.y = top - fr.height
        panel.setFrame(fr, display: true)
    }

    func schedule(fast f: Bool) {
        fast = f; timer?.invalidate()
        // 8 fps while something moves, 1 fps when the office is quiet.
        timer = Timer.scheduledTimer(withTimeInterval: f ? 0.16 : 1.0, repeats: true) { [weak self] _ in self?.step() }
        timer?.tolerance = f ? 0.03 : 0.3
    }

    func step() {
        tick += 1
        let changed = feed.read(into: office, replay: false)
        if tick % (fast ? 40 : 5) == 0 { pollSystem() }
        office.prune(now: Date().timeIntervalSince1970)
        view.frameNo += fast ? 1 : 8
        if panel.occlusionState.contains(.visible) { view.needsDisplay = true }
        snapshotIfRequested()
        let wantFast = office.busy || changed
        if wantFast != fast { schedule(fast: wantFast) }
    }

    /// Touch $AGENT_OFFICE_DIR/snap.request to get the current frame as snap.png (no screen-recording permission needed).
    func snapshotIfRequested() {
        let req = baseDir + "/snap.request"
        guard FileManager.default.fileExists(atPath: req) else { return }
        try? FileManager.default.removeItem(atPath: req)
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: baseDir + "/snap.png"))
    }

    /// Watchers are the background PR watcher scripts; Docker is Docker Desktop running.
    func pollSystem() {
        office.docker = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.docker.docker" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-lf", "watch_[0-9]+\\.sh"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var found: [String] = []
        for line in out.split(separator: "\n") {
            if let r = line.range(of: #"watch_(\d+)\.sh"#, options: .regularExpression) {
                let n = "#" + line[r].dropFirst(6).dropLast(3)
                if !found.contains(n) { found.append(n) }
            }
        }
        office.watchers = found
    }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
