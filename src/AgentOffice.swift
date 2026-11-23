// Agent Office: a floating pixel-art office, seen from a three-quarter view, that shows what
// Claude Code agents are doing, plus a machine room with the dev infrastructure that is running.
// Reads $AGENT_OFFICE_DIR/events.jsonl (default ~/agent-office), written by hook.sh.
// The static room is rendered once into a cached image; each frame draws only sprites and text.
import Cocoa

let env = ProcessInfo.processInfo.environment
let baseDir = env["AGENT_OFFICE_DIR"] ?? (NSHomeDirectory() + "/agent-office")

// MARK: - Model

struct Ev: Decodable {
    let t: Double; let ev: String; let sid: String; let proj: String
    let aid: String; let atype: String; let tool: String; let bg: Bool; let ntype: String; let d: String
}

struct BoardItem: Decodable { let repo: String?; let number: Int?; let title: String; let stage: String; let note: String? }
/// Something on GitHub waiting for you: a review request (kind "pr") or an assigned issue ("issue").
struct YourItem: Decodable { let kind: String; let repo: String?; let number: Int?; let title: String; let url: String?; let since: Double? }
struct Board: Decodable { let updated: Double?; let items: [BoardItem]; let yours: [YourItem]? }

/// Why a session is waiting for you: its turn ended, it asks for a permission, or it asked a question.
enum WaitKind { case done, perm, ask }
struct Wait { var kind: WaitKind; var since: Double; var proj: String; var aid: String; var detail: String }

/// One row of the "Tu turno" panel.
struct Turn { let key: String; let kind: String; let title: String; let sub: String; let since: Double; let url: String? }

/// "hace 4 min", "hace 2 h"...
func ago(_ secs: Double) -> String {
    let s = max(0, Int(secs))
    if s < 60 { return "ahora" }
    if s < 3600 { return "hace \(s / 60) min" }
    if s < 86400 { return "hace \(s / 3600) h" }
    return "hace \(s / 86400) d"
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

/// Short, readable detail: file name instead of a path, no leading `cd <dir> &&`, ~ for home.
func tidy(_ d: String) -> String {
    if d.hasPrefix("/") && !d.contains(" ") { return (d as NSString).lastPathComponent }
    var s = d.replacingOccurrences(of: #"^cd \S+ (&& |; )?"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    return s
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

// MARK: - Machine room model

struct Device: Decodable { var kind: String; var name: String; var link: String? }   // kind: android | ios
struct Server: Decodable { var port: Int; var kind: String }

struct Machines: Decodable {
    var docker = false
    var dockerStuck = false
    var containers: [String] = []
    var devices: [Device] = []
    var servers: [Server] = []
    var watchers: [String] = []
    init() {}
    enum K: String, CodingKey { case docker, dockerStuck, containers, devices, servers, watchers }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        docker = try c.decodeIfPresent(Bool.self, forKey: .docker) ?? false
        dockerStuck = try c.decodeIfPresent(Bool.self, forKey: .dockerStuck) ?? false
        containers = try c.decodeIfPresent([String].self, forKey: .containers) ?? []
        devices = try c.decodeIfPresent([Device].self, forKey: .devices) ?? []
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        watchers = try c.decodeIfPresent([String].self, forKey: .watchers) ?? []
    }
}

final class Office {
    var agents: [String: Agent] = [:]
    var pendingDesc: [String: [String]] = [:]
    var board: [BoardItem] = []
    var yours: [YourItem] = []
    var boardUpdated = 0.0
    /// Sessions waiting for you, by session id. Kept for up to `waitMax` even after the robot leaves.
    var waits: [String: Wait] = [:]
    var turns: [Turn] = []
    let waitMax = 8 * 3600.0
    var machines = Machines()
    let slots = 6
    /// Live events use the wall clock for arrivals and departures: hook times are whole seconds,
    /// which would eat into the walk animation.
    var live = false
    func clock(_ e: Ev) -> Double { live ? Date().timeIntervalSince1970 : e.t }

    func session(_ e: Ev) -> Agent {
        let key = "s:" + e.sid
        if let a = agents[key] { if a.leaving != nil { a.leaving = nil }; return a }
        let a = Agent(id: key, name: "Líder · " + e.proj, kind: "lead", now: clock(e))
        agents[key] = a; assign(a); return a
    }

    func sub(_ e: Ev) -> Agent {
        let key = "a:" + e.aid
        if let a = agents[key] { return a }
        let a = Agent(id: key, name: label(forKind: e.atype), kind: e.atype, now: clock(e))
        agents[key] = a; assign(a); return a
    }

    func assign(_ a: Agent) {
        let used = Set(agents.values.map { $0.slot })
        for s in 0..<slots where !used.contains(s) { a.slot = s; return }
        a.slot = -1
    }

    /// Tracks when a session needs you. Only the main session's Stop counts as "your turn"
    /// (subagent stops are for the lead to handle).
    func track(_ e: Ev) {
        let sid = e.sid
        guard !sid.isEmpty else { return }
        let lead = e.aid.isEmpty
        switch e.ev {
        case "SessionEnd", "UserPromptSubmit": waits[sid] = nil
        case "Stop": if lead { waits[sid] = Wait(kind: .done, since: e.t, proj: e.proj, aid: "", detail: "") }
        case "Notification":
            switch e.ntype {
            case "idle_prompt":
                if waits[sid] == nil { waits[sid] = Wait(kind: .done, since: e.t, proj: e.proj, aid: "", detail: "") }
            case "elicitation_dialog":
                waits[sid] = Wait(kind: .ask, since: e.t, proj: e.proj, aid: e.aid, detail: e.d)
            case "permission_prompt", "":
                guard e.ntype != "" || e.d.lowercased().contains("permission") else { break }
                // AskUserQuestion also raises a permission prompt: keep it as a question.
                if let w = waits[sid], w.kind == .ask, w.aid == e.aid { break }
                waits[sid] = Wait(kind: .perm, since: e.t, proj: e.proj, aid: e.aid, detail: e.d)
            default: break
            }
        case "PreToolUse" where e.tool == "AskUserQuestion":
            waits[sid] = Wait(kind: .ask, since: e.t, proj: e.proj, aid: e.aid, detail: e.d)
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStop":
            guard let w = waits[sid] else { break }
            // A permission or a question is answered when that same agent moves on. A finished turn
            // ends when the main session starts working again (a background task woke it up).
            if w.kind != .done ? w.aid == e.aid : (lead && e.ev == "PreToolUse") { waits[sid] = nil }
        default: break
        }
    }

    /// The lead's turn ended and it waits for your instructions.
    func turnWait(_ a: Agent) -> Wait? {
        guard a.kind == "lead", a.leaving == nil, let w = waits[String(a.id.dropFirst(2))], w.kind == .done else { return nil }
        return w
    }

    /// Everything that needs you, oldest first.
    func computeTurns() -> [Turn] {
        var out: [Turn] = []
        for (sid, w) in waits {
            let key = "s:\(sid):\(w.kind):\(Int(w.since))"
            switch w.kind {
            case .done:
                out.append(Turn(key: key, kind: "done", title: "Sesión \(w.proj) terminó", sub: "esperando tus instrucciones", since: w.since, url: nil))
            case .perm:
                var sub = "apruébalo en la terminal"
                if let r = w.detail.range(of: #"to use \S+"#, options: .regularExpression) { sub = "quiere usar " + w.detail[r].dropFirst(7) }
                out.append(Turn(key: key, kind: "perm", title: "Sesión \(w.proj) te pide permiso", sub: sub, since: w.since, url: nil))
            case .ask:
                out.append(Turn(key: key, kind: "ask", title: "Sesión \(w.proj) te hizo una pregunta", sub: w.detail.isEmpty ? "responde en la terminal" : w.detail, since: w.since, url: nil))
            }
        }
        for y in yours {
            let n = y.number.map { "#\($0) " } ?? ""
            let repo = y.repo.map { " · " + $0 } ?? ""
            let pr = y.kind == "pr"
            out.append(Turn(key: "\(y.kind):\(y.repo ?? "")\(n)", kind: pr ? "pr" : "issue", title: n + y.title,
                            sub: (pr ? "revisar PR" : "issue asignado") + repo, since: y.since ?? boardUpdated, url: y.url))
        }
        return out.sorted { $0.since != $1.since ? $0.since < $1.since : $0.key < $1.key }
    }

    func handle(_ e: Ev) {
        track(e)
        let target: Agent = e.aid.isEmpty ? session(e) : sub(e)
        target.last = e.t
        switch e.ev {
        case "SessionStart": target.act = .idle; target.detail = "llegó a la oficina"
        case "SessionEnd": target.leaving = clock(e); target.act = .done
        case "UserPromptSubmit": target.act = .think; target.detail = "pensando…"
        case "PreToolUse":
            target.act = act(forTool: e.tool)
            target.detail = tidy(e.d.isEmpty ? e.tool : e.d)
            if e.tool == "Agent" || e.tool == "Task" { pendingDesc[e.sid, default: []].append(e.d) }
        case "PostToolUse", "PostToolUseFailure":
            if target.act != .wait { target.act = .think }
        case "SubagentStart":
            target.act = .think
            if var q = pendingDesc[e.sid], !q.isEmpty {
                let d = q.removeFirst(); pendingDesc[e.sid] = q; target.detail = d
                let l = d.lowercased()
                let pr = d.range(of: #"#\d+"#, options: .regularExpression).map { " " + d[$0] } ?? ""
                if l.contains("review") || l.contains("revis") { target.kind = "reviewer"; target.name = "Revisor" + pr }
                else if l.contains("verif") && target.kind != "ac-verifier" { target.name = "Verificador" + pr }
            }
        case "SubagentStop": target.act = .done; target.detail = "terminó"; target.leaving = clock(e)
        case "Notification":
            // "Waiting for your input" after a finished turn is your turn, not a permission (no red "!").
            if e.ntype == "idle_prompt" { if target.act != .wait { target.act = .idle; target.detail = "listo, esperando" } }
            else { target.act = .wait; target.detail = "necesita tu permiso" }
        case "Stop": if e.aid.isEmpty { target.act = .idle; target.detail = "listo, esperando" }
        case "PreCompact": target.act = .think; target.detail = "ordenando su memoria"
        default: break
        }
    }

    func prune(now: Double) {
        for (k, a) in agents {
            if let l = a.leaving, now - l > leaveTotal { agents.removeValue(forKey: k); continue }
            let quiet = now - a.last
            // A lead whose turn ended stays at its desk while it waits for you.
            if turnWait(a) != nil { continue }
            if a.kind == "lead" ? quiet > 1800 : quiet > 1200 { agents.removeValue(forKey: k) }
        }
        for (sid, w) in waits where now - w.since > waitMax { waits[sid] = nil }
        for a in agents.values where a.slot < 0 { assign(a) }
    }

    /// Someone is working (6 fps); otherwise the office ticks at 1 fps.
    var busy: Bool { agents.values.contains { $0.act != .idle } }

    /// Someone is walking through the door (12 fps for a smooth walk).
    func walking(now: Double) -> Bool {
        agents.values.contains { a in
            if a.leaving != nil { return true }
            return a.born > 0 && now - a.born < walkMax + 0.2
        }
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
        let now = Date().timeIntervalSince1970
        let cutoff = now - 1800, waitCutoff = now - o.waitMax
        o.live = !replay
        for line in data[..<lastNL].split(separator: 10) {
            guard let e = try? dec.decode(Ev.self, from: Data(line)) else { continue }
            if replay && e.t < cutoff { if e.t >= waitCutoff { o.track(e) }; continue }
            o.handle(e)
        }
        if replay {
            // A session that is still waiting for you gets its robot back at its desk.
            for (sid, w) in o.waits where w.kind == .done && o.agents["s:" + sid] == nil {
                let a = Agent(id: "s:" + sid, name: "Líder · " + w.proj, kind: "lead", now: w.since)
                a.act = .idle; a.detail = "listo, esperando"; o.agents[a.id] = a; o.assign(a)
            }
            for a in o.agents.values { a.born = 0 }
        }
        return true
    }
}

// MARK: - Machine probes (background queue only)

/// Runs a tool with a deadline and returns its stdout. Non-blocking reads, so a child that
/// leaves a daemon holding the pipe can never hang the probe.
func run(_ path: String, _ args: [String], timeout: Double = 4) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    var e = env; e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"; p.environment = e
    let fd = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    do { try p.run() } catch { return nil }
    var out = Data(); var buf = [UInt8](repeating: 0, count: 32768)
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 { out.append(buf, count: n); continue }
        if n == 0 { break }
        if !p.isRunning {
            let m = read(fd, &buf, buf.count)
            if m > 0 { out.append(buf, count: m); continue }
            break
        }
        if Date() > deadline { p.terminate(); return nil }
        usleep(15000)
    }
    return String(decoding: out, as: UTF8.self)
}

final class Probe {
    let queue = DispatchQueue(label: "agent-office.probe", qos: .utility)
    var busy = false
    var dockerRetry = 0.0
    let home = NSHomeDirectory()

    func first(_ paths: [String?]) -> String? {
        paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func appRunning(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    func collect() -> Machines {
        if let demo = env["AGENT_OFFICE_DEMO_MACHINES"] {
            guard let d = FileManager.default.contents(atPath: demo), let m = try? JSONDecoder().decode(Machines.self, from: d) else { return Machines() }
            return m
        }
        var m = Machines()
        // One ps call feeds the watchers, the emulators, adb and the server classification.
        var args: [Int: String] = [:]
        var avds: [String] = []
        var adbServer = false
        for line in (run("/bin/ps", ["-axww", "-o", "pid=,args="]) ?? "").split(separator: "\n") {
            let t = line.drop { $0 == " " }
            guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
            let a = String(t[t.index(after: sp)...]); args[pid] = a
            if let r = a.range(of: #"watch_(\d+)\.sh"#, options: .regularExpression) {
                let n = "#" + a[r].dropFirst(6).dropLast(3)
                if !m.watchers.contains(n) { m.watchers.append(n) }
            }
            let exe = (String(a.split(separator: " ").first ?? "") as NSString).lastPathComponent
            if exe.hasPrefix("qemu-system") {
                var name = "emulador"
                if let r = a.range(of: #"-avd \S+"#, options: .regularExpression) { name = String(a[r].dropFirst(5)) }
                avds.append(name)
            }
            if exe == "adb" && a.contains("server") { adbServer = true }
        }
        // Docker Desktop: only when the app is running.
        if appRunning("com.docker.docker") {
            m.docker = true
            let docker = first(["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                "/Applications/Docker.app/Contents/Resources/bin/docker", home + "/.docker/bin/docker"])
            // A daemon that does not answer is retried once a minute, not every probe.
            let now = Date().timeIntervalSince1970
            let out = now < dockerRetry ? nil : docker.flatMap { run($0, ["ps", "--format", "{{.Names}}\t{{.Image}}"], timeout: 3) }
            if out == nil, docker != nil { m.dockerStuck = true; if now >= dockerRetry { dockerRetry = now + 60 } } else { dockerRetry = 0 }
            if let out = out {
                var seen = Set<String>()
                for l in out.split(separator: "\n") {
                    let parts = l.split(separator: "\t").map(String.init)
                    guard parts.count == 2 else { continue }
                    var img = parts[1]
                    if let at = img.firstIndex(of: "@") { img = String(img[..<at]) }
                    img = (img as NSString).lastPathComponent
                    if let c = img.lastIndex(of: ":") { img = String(img[..<c]) }
                    let short = seen.contains(img) ? String(parts[0].prefix(14)) : img
                    seen.insert(img); m.containers.append(short)
                }
            }
        }
        // Android: emulator processes, plus adb (only if its server already runs, so we never start it).
        let adb = first([env["ANDROID_HOME"].map { $0 + "/platform-tools/adb" }, env["ANDROID_SDK_ROOT"].map { $0 + "/platform-tools/adb" },
                         home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"])
        var pending = avds
        if adbServer || !avds.isEmpty, let adb = adb, let out = run(adb, ["devices", "-l"]) {
            for l in out.split(separator: "\n").dropFirst() {
                let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 2, f[1] == "device" || f[1] == "offline" || f[1] == "unauthorized" else { continue }
                if f[0].hasPrefix("emulator-") {
                    let name = pending.isEmpty ? f[0] : pending.removeFirst()
                    m.devices.append(Device(kind: "android", name: name, link: "emulador"))
                } else {
                    let model = f.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
                    m.devices.append(Device(kind: "android", name: model ?? f[0], link: "USB"))
                }
            }
        }
        for name in pending { m.devices.append(Device(kind: "android", name: name, link: "emulador")) }
        // iOS simulator: only while Simulator.app is open.
        if appRunning("com.apple.iphonesimulator"), let out = run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: 6),
           let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let byRuntime = j["devices"] as? [String: [[String: Any]]] {
            for (_, list) in byRuntime.sorted(by: { $0.key < $1.key }) {
                for d in list where (d["state"] as? String) == "Booted" {
                    m.devices.append(Device(kind: "ios", name: d["name"] as? String ?? "iPhone", link: "simulador"))
                }
            }
        }
        // Local servers: TCP listeners of this user, below the ephemeral range.
        if let out = run("/usr/sbin/lsof", ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "+c", "0", "-Fpcn"]) {
            var pid = 0, cmd = ""
            var byPort: [Int: Server] = [:]
            for l in out.split(separator: "\n") {
                guard let tag = l.first else { continue }
                let v = String(l.dropFirst())
                switch tag {
                case "p": pid = Int(v) ?? 0
                case "c": cmd = v
                case "n":
                    guard let c = v.lastIndex(of: ":"), let port = Int(v[v.index(after: c)...]), port <= 49151, byPort[port] == nil else { continue }
                    if let k = Probe.serverKind(port: port, cmd: cmd, args: args[pid] ?? "") { byPort[port] = Server(port: port, kind: k) }
                default: break
                }
            }
            m.servers = byPort.values.sorted { $0.port < $1.port }
        }
        return m
    }

    static let ignored = ["controlce", "rapportd", "sharingd", "docker", "vpnkit", "airplay", "spotify", "dropbox", "figma",
                          "adobe", "slack", "discord", "zoom", "raycast", "code helper", "cursor", "electron", "jetbrains",
                          "studio", "qemu", "adb", "simulator", "launchd", "1password", "chrome", "firefox", "safari",
                          "steam", "onedrive", "claude", "logi", "teams", "webex", "obs"]
    static let devCommands = ["node", "bun", "deno", "python", "ruby", "java", "php", "postgres", "redis-server", "mysqld",
                              "mongod", "nginx", "httpd", "caddy", "beam.smp", "dotnet", "uvicorn", "gunicorn", "puma", "hugo"]
    static let devPorts: Set<Int> = [3000, 3001, 3002, 3003, 4000, 4200, 4321, 5000, 5173, 5174, 5432, 6379, 3306, 27017,
                                     8000, 8008, 8080, 8081, 8088, 8888, 9000, 19000, 19001, 19002]

    /// Friendly name for a listening port, or nil when it is not a dev server.
    static func serverKind(port: Int, cmd: String, args: String) -> String? {
        let c = cmd.lowercased(), a = args.lowercased()
        if ignored.contains(where: { c.contains($0) }) { return nil }
        let isDev = devCommands.contains { c.hasPrefix($0) }
        guard isDev || devPorts.contains(port) else { return nil }
        let js = c.hasPrefix("node") || c.hasPrefix("bun") || c.hasPrefix("deno")
        if a.contains("expo") { return port == 8081 ? "Metro" : "Expo" }
        if port == 8081 && (js || a.contains("metro") || a.contains("react-native")) { return "Metro" }
        if a.contains("metro") || a.contains("react-native start") { return "Metro" }
        if c.hasPrefix("postgres") || port == 5432 { return "postgres" }
        if c.hasPrefix("redis") || port == 6379 { return "redis" }
        if c.hasPrefix("mysqld") || port == 3306 { return "mysql" }
        if c.hasPrefix("mongod") || port == 27017 { return "mongo" }
        if js {
            if a.contains("nest") { return "nest" }
            if a.contains("next") { return "next" }
            if a.contains("vite") || port == 5173 || port == 5174 { return "vite" }
            if a.contains("storybook") { return "storybook" }
            if a.contains("webpack") { return "webpack" }
            if a.contains("ng serve") || a.contains("angular") || port == 4200 { return "angular" }
            if a.contains("astro") || port == 4321 { return "astro" }
            if [3000, 3001, 8080, 8000].contains(port) { return "web" }
            return "node"
        }
        if c.hasPrefix("python") || c.hasPrefix("uvicorn") || c.hasPrefix("gunicorn") {
            if a.contains("uvicorn") || a.contains("fastapi") { return "fastapi" }
            if a.contains("manage.py") || a.contains("django") { return "django" }
            if a.contains("flask") { return "flask" }
            if a.contains("http.server") { return "http" }
            return "python"
        }
        if c.hasPrefix("ruby") || c.hasPrefix("puma") { return "rails" }
        if c.hasPrefix("java") { return "java" }
        if c.hasPrefix("php") { return "php" }
        if c.hasPrefix("nginx") { return "nginx" }
        if c.hasPrefix("httpd") || c.hasPrefix("caddy") { return "http" }
        if [3000, 3001, 5000, 8000, 8080, 8888].contains(port) { return "web" }
        return String(c.prefix(8))
    }
}

// MARK: - Drawing primitives (art pixels; P screen points per art pixel)

enum G {
    static var ctx: CGContext!
    static var P: CGFloat = 3
    static var colors: [UInt64: CGColor] = [:]
}

func cg(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    let key = UInt64(hex) << 8 | UInt64(a * 255)
    if let c = G.colors[key] { return c }
    let c = CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    G.colors[key] = c; return c
}

func ns(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ col: UInt32, _ a: CGFloat = 1) {
    let P = G.P
    G.ctx.setFillColor(cg(col, a))
    G.ctx.fill(CGRect(x: CGFloat(x) * P, y: CGFloat(y) * P, width: CGFloat(w) * P, height: CGFloat(h) * P))
}

/// Mixes a color toward white (t > 0) or black (t < 0).
func shade(_ hex: UInt32, _ t: Double) -> UInt32 {
    func ch(_ v: UInt32) -> UInt32 {
        let f = Double(v)
        let r = t >= 0 ? f + (255 - f) * t : f * (1 + t)
        return UInt32(max(0, min(255, r.rounded())))
    }
    return ch((hex >> 16) & 255) << 16 | ch((hex >> 8) & 255) << 8 | ch(hex & 255)
}

func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    func ch(_ s: UInt32) -> UInt32 { let x = Double((a >> s) & 255), y = Double((b >> s) & 255); return UInt32((x + (y - x) * t).rounded()) }
    return ch(16) << 16 | ch(8) << 8 | ch(0)
}

func hash2(_ a: Int, _ b: Int) -> Int {
    var h = a &* 374761393 &+ b &* 668265263
    h = (h ^ (h >> 13)) &* 1274126177
    return abs(h ^ (h >> 16))
}

/// Renders art-pixel drawing (P = 1) into a cached image.
func makeImage(_ w: Int, _ h: Int, _ draw: () -> Void) -> CGImage? {
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
    let savedCtx = G.ctx, savedP = G.P
    G.ctx = c; G.P = 1
    draw()
    G.ctx = savedCtx; G.P = savedP
    return c.makeImage()
}

/// Draws a cached image at art coordinates, nearest-neighbor, into the (flipped) current context.
func blit(_ img: CGImage, _ x: Int, _ y: Int) {
    let P = G.P, c = G.ctx!
    let r = CGRect(x: CGFloat(x) * P, y: CGFloat(y) * P, width: CGFloat(img.width) * P, height: CGFloat(img.height) * P)
    c.saveGState(); c.interpolationQuality = .none
    c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(img, in: CGRect(origin: .zero, size: r.size))
    c.restoreGState()
}

// MARK: - Layout (art pixels)

let W = 296, H = 164
let deskXs = [8, 54, 100], deskYs = [74, 128]
let doorX = 119, doorTop = 24
let leaveSit = 1.0, walkMax = 1.5
let leaveTotal = leaveSit + walkMax + 0.4

func deskOrigin(_ slot: Int) -> (Int, Int) { (deskXs[slot % 3], deskYs[slot / 3]) }

/// Path of a robot's head (top-left) from the door to its chair.
func walkPath(_ slot: Int) -> [(Double, Double)] {
    let (dx, dy) = deskOrigin(slot)
    let sx = Double(dx + 5), sy = Double(dy - 15)
    if slot < 3 { return [(Double(doorX), Double(doorTop)), (Double(doorX), 36), (sx, 36), (sx, sy)] }
    return [(Double(doorX), Double(doorTop)), (Double(doorX), 36), (134, 36), (134, 97), (sx, 97), (sx, sy)]
}

func pathLength(_ p: [(Double, Double)]) -> Double {
    var l = 0.0
    for i in 1..<p.count { l += hypot(p[i].0 - p[i - 1].0, p[i].1 - p[i - 1].1) }
    return l
}

func walkDuration(_ slot: Int) -> Double { min(walkMax, max(0.9, pathLength(walkPath(slot)) / 150)) }

func point(on p: [(Double, Double)], _ t: Double) -> (Double, Double) {
    var left = max(0, min(1, t)) * pathLength(p)
    for i in 1..<p.count {
        let a = p[i - 1], b = p[i]
        let l = hypot(b.0 - a.0, b.1 - a.1)
        if left <= l, l > 0 { let k = left / l; return (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k) }
        left -= l
    }
    return p[p.count - 1]
}

enum Pose { case seated, walking(x: Int, y: Int, t: Double), gone }

func agentPose(_ a: Agent, now: Double) -> Pose {
    guard a.slot >= 0 else { return .gone }
    let dur = walkDuration(a.slot)
    if let l = a.leaving {
        let e = now - l
        if e < leaveSit { return .seated }
        let t = 1 - (e - leaveSit) / dur
        if t <= 0 { return .gone }
        let (x, y) = point(on: walkPath(a.slot), t); return .walking(x: Int(x.rounded()), y: Int(y.rounded()), t: t)
    }
    if a.born > 0, now - a.born < dur {
        let t = (now - a.born) / dur
        let (x, y) = point(on: walkPath(a.slot), t); return .walking(x: Int(x.rounded()), y: Int(y.rounded()), t: t)
    }
    return .seated
}

let kindColor: [String: UInt32] = [
    "lead": 0xE07A4F, "ac-verifier": 0x4FB477, "Explore": 0x4F8FE0, "general-purpose": 0x9B6FD6, "claude": 0x9B6FD6,
    "fork": 0xE0C04F, "reviewer": 0x3FB8A8, "Plan": 0x4FC6C6, "web-fetch": 0xD65F9B, "watcher": 0x8A93A6,
]

// Palette.
let ink: UInt32 = 0x1B1D2B
let cream: UInt32 = 0xF2E9DC
let green: UInt32 = 0x7CF29A
let gold: UInt32 = 0xF2C14E
let red: UInt32 = 0xE04848
let skyBlue: UInt32 = 0x7EC8F0

// MARK: - Static scene (cached)

struct Sky { let top: UInt32; let bottom: UInt32; let night: Bool; let key: String }

func sky(hour: Int) -> Sky {
    switch hour {
    case 5..<7: return Sky(top: 0x6C7BB8, bottom: 0xF2B5A0, night: false, key: "dawn")
    case 7..<17: return Sky(top: 0x5FB4EA, bottom: 0xB4E2F7, night: false, key: "day")
    case 17..<19: return Sky(top: 0xE9875E, bottom: 0xF6C98A, night: false, key: "dusk")
    case 19..<20: return Sky(top: 0x3A3F7A, bottom: 0xC9708A, night: false, key: "evening")
    default: return Sky(top: 0x101631, bottom: 0x28345E, night: true, key: "night")
    }
}

func drawBackground(_ s: Sky) {
    // --- Office: back wall.
    px(0, 0, 146, 3, 0x232A3A)
    px(0, 3, 146, 27, 0x3E4A61)
    for x in stride(from: 4, to: 146, by: 6) { px(x, 3, 1, 26, 0x43506A) }
    px(0, 29, 146, 1, 0x5A6683); px(0, 30, 146, 8, 0x35405A)
    for x in stride(from: 2, to: 146, by: 12) { px(x, 31, 1, 6, 0x303A52) }
    px(0, 38, 146, 4, 0x2A3142); px(0, 38, 146, 1, 0x4A5570)
    // Floor: wooden planks.
    let tones: [UInt32] = [0x8A6A4E, 0x84654A, 0x8F6E51, 0x876749]
    for r in 0..<25 {
        let y = 42 + r * 5
        var x = -((r * 9) % 24)
        var seg = 0
        while x < 146 {
            let x0 = max(0, x), x1 = min(146, x + 24)
            px(x0, y, x1 - x0, 5, tones[hash2(r, seg) % 4])
            px(x0, y, x1 - x0, 1, 0x95765A)
            if x > 0 { px(x, y, 1, 5, 0x6E5340) }
            x += 24; seg += 1
        }
        px(0, y + 4, 146, 1, 0x6E5340)
    }
    px(3, 42, 143, 2, 0x000000, 0.2)
    // Left wall seen from above (depth).
    px(0, 3, 3, H - 3, 0x2A3142); px(2, 3, 1, H - 3, 0x4A5570); px(3, 42, 2, H - 42, 0x000000, 0.15)
    // Rug under the desks.
    px(5, 50, 137, 112, 0x363F56)
    px(6, 51, 135, 110, 0x45506B)
    px(9, 54, 129, 1, 0x8A7A5A); px(9, 157, 129, 1, 0x8A7A5A); px(9, 54, 1, 104, 0x8A7A5A); px(137, 54, 1, 104, 0x8A7A5A)
    for y in stride(from: 60, to: 154, by: 10) {
        for x in stride(from: 15 + (y / 10 % 2) * 6, to: 134, by: 12) { px(x, y, 2, 1, 0x515D7B); px(x, y + 1, 2, 1, 0x3F4962) }
    }
    // Window with the sky of the hour (clouds and stars move on top).
    px(8, 5, 30, 20, 0x2A3142); px(9, 6, 28, 18, 0xD9CBB0)
    for r in 0..<16 { px(10, 7 + r, 26, 1, mix(s.top, s.bottom, Double(r / 4) / 3)) }
    if s.night { px(30, 9, 3, 3, 0xF2EBC9); px(31, 9, 2, 1, 0xFFF8DC) }
    else if s.key == "day" { px(31, 8, 3, 3, 0xFFF1A8) }
    else { px(27, 18, 5, 3, 0xFFD08A); px(28, 17, 3, 1, 0xFFD08A) }
    px(7, 25, 32, 2, 0xE5D9C2); px(8, 27, 30, 1, 0x000000, 0.25)
    // Counter with the coffee machine.
    px(6, 33, 34, 4, 0xBDB5A6); px(6, 33, 34, 1, 0xD6CFC2)
    px(6, 37, 34, 9, 0x5C4A3E); px(6, 37, 34, 1, 0x4A3B31); px(22, 38, 1, 7, 0x4A3B31)
    px(19, 41, 1, 1, 0xC9A66B); px(25, 41, 1, 1, 0xC9A66B); px(6, 46, 34, 2, 0x000000, 0.22)
    px(11, 24, 9, 2, 0x4A5166); px(11, 26, 9, 8, 0x2A2F3D); px(12, 27, 3, 2, 0x15171F)
    px(13, 30, 5, 3, 0x15171F); px(14, 31, 3, 2, cream); px(11, 33, 9, 1, 0x3A4052)
    px(25, 30, 3, 3, 0xE07A4F); px(28, 31, 1, 1, 0xE07A4F); px(31, 30, 3, 3, cream); px(34, 31, 1, 1, cream)
    px(36, 29, 2, 4, 0x8A93A6)
    // Title plaque and clock.
    px(44, 5, 54, 15, 0x1E2333); px(45, 6, 52, 13, 0x262C3F); px(44, 20, 54, 1, 0x000000, 0.25)
    px(101, 7, 16, 9, 0x2A3142); px(102, 8, 14, 7, 0x10121A)
    // Door frame and exit sign (the door itself is drawn per frame).
    px(117, 12, 16, 30, 0x2A3142)
    px(120, 8, 10, 3, 0x2F7A4A); px(121, 9, 8, 1, green)
    px(117, 42, 16, 3, 0x3A3F55)
    // Plant in the corner.
    px(134, 44, 12, 2, 0x000000, 0.22)
    px(136, 36, 9, 8, 0xA0583C); px(135, 35, 11, 2, 0xB86A4A); px(144, 37, 1, 7, 0x7E4430)
    let leaves: [(Int, Int, Int, Int, UInt32)] = [(137, 24, 3, 11, 0x3E9E5B), (140, 20, 3, 15, 0x4FB477), (143, 25, 3, 10, 0x3E9E5B),
                                                  (135, 28, 3, 6, 0x358A4E), (139, 23, 1, 4, 0x6FCF8E), (142, 22, 1, 5, 0x6FCF8E)]
    for l in leaves { px(l.0, l.1, l.2, l.3, l.4) }
    // Chairs (robots sit in front of them; desks are drawn per frame on top).
    for slot in 0..<6 {
        let (dx, dy) = deskOrigin(slot)
        px(dx + 4, dy - 11, 16, 9, 0x2E3447); px(dx + 5, dy - 12, 14, 1, 0x2E3447)
        px(dx + 5, dy - 11, 14, 1, 0x4A5370); px(dx + 4, dy - 10, 1, 7, 0x3A4158); px(dx + 19, dy - 10, 1, 7, 0x232838)
        px(dx + 7, dy - 9, 10, 1, 0x3A4158); px(dx + 7, dy - 6, 10, 1, 0x3A4158)
        px(dx + 11, dy - 2, 2, 2, 0x232838); px(dx + 3, dy - 1, 18, 1, 0x000000, 0.25)
    }
    // Partition wall.
    px(146, 0, 3, H, 0x232A3A); px(146, 0, 1, H, 0x4A5570)

    // --- Machine room.
    px(149, 0, 63, 3, 0x1C2230); px(149, 3, 63, 35, 0x2E3648)
    for x in stride(from: 152, to: 212, by: 8) { px(x, 3, 1, 35, 0x343D51) }
    px(149, 38, 63, 4, 0x1E2433); px(149, 38, 63, 1, 0x3E475E)
    px(152, 4, 57, 5, 0x1A1F2C)
    for ty in 0..<16 {
        for tx in 0..<8 {
            let x = 149 + tx * 8, y = 42 + ty * 8
            px(x, y, 8, 8, (tx + ty) % 2 == 0 ? 0x4B5263 : 0x474E5F)
            px(x, y, 8, 1, 0x555D70); px(x, y, 1, 8, 0x3B4150)
            if hash2(tx, ty) % 7 == 0 { for v in 0..<3 { px(x + 2, y + 2 + v * 2, 4, 1, 0x3B4150) } }
        }
    }
    px(149, 42, 63, 2, 0x000000, 0.25)
    // Docker rack.
    px(152, 52, 19, 3, 0x000000, 0.3)
    px(152, 11, 18, 3, 0x4A5166); px(152, 11, 18, 1, 0x5E6780)
    px(152, 14, 18, 39, 0x1E2230); px(153, 15, 16, 37, 0x14161F)
    for i in 0..<7 {
        let y = 16 + i * 5
        px(154, y, 14, 4, 0x262A38); px(159, y + 1, 7, 1, 0x1B1E28); px(159, y + 2, 7, 1, 0x1B1E28)
    }
    // Device table.
    px(151, 77, 59, 2, 0x000000, 0.25)
    px(151, 66, 59, 5, 0x5A6275); px(151, 66, 59, 1, 0x6E7790)
    px(151, 71, 59, 6, 0x3A4152); px(151, 76, 59, 1, 0x2E3442)
    // Server cabinet.
    px(151, 128, 59, 2, 0x000000, 0.3)
    px(151, 90, 59, 3, 0x4A5166); px(151, 90, 59, 1, 0x5E6780)
    px(151, 93, 59, 35, 0x1E2230); px(152, 94, 57, 33, 0x171A25)

    // --- Board wall.
    px(212, 0, 84, H, 0x2B3243); px(212, 0, 2, H, 0x1C2230)
    px(215, 4, 78, 157, 0x000000, 0.25)
    px(214, 3, 78, 156, 0x7A5238); px(214, 3, 78, 1, 0x9A6E4C)
    px(216, 5, 74, 152, 0xC69C6D)
    for i in 0..<220 { let h = hash2(i, 7); px(216 + h % 74, 5 + (h / 74) % 152, 1, 1, i % 2 == 0 ? 0xB58A5C : 0xD4AC7E) }
}

/// Desk with its monitor and keyboard, drawn on top of the robot sitting at it.
func drawDeskSprite() {
    px(20, 0, 14, 9, 0x23283A); px(31, 0, 3, 9, 0x161A26); px(21, 1, 10, 7, 0x10111A); px(20, 8, 14, 1, 0x161A26)
    px(25, 9, 3, 2, 0x161A26)
    px(0, 10, 34, 10, 0xC8A27A); px(0, 10, 34, 1, 0xD9B78F); px(0, 19, 34, 1, 0xB08A64)
    px(23, 11, 7, 1, 0x23283A)
    px(5, 13, 11, 3, 0x3A3F52); for k in 0..<5 { px(6 + k * 2, 14, 1, 1, 0x6B7088) }
    px(17, 15, 4, 3, 0xF2E9DC); px(18, 16, 2, 1, 0xB0B6C8); px(21, 16, 1, 2, 0xD9CBB0)
    px(0, 20, 34, 6, 0x9C7656); px(0, 25, 34, 1, 0x7E5E44)
    px(23, 21, 9, 3, 0x8E6A4C); px(26, 22, 3, 1, 0xD9B78F)
    px(1, 26, 33, 2, 0x000000, 0.22)
}

// MARK: - View

final class OfficeView: NSView {
    let office: Office
    var P: CGFloat = 3
    var frameNo = 0
    var bg: CGImage?; var bgKey = ""
    lazy var desk: CGImage? = makeImage(34, 28, drawDeskSprite)
    static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm"; return d }()
    var fonts: [String: NSFont] = [:]
    init(office: Office) { self.office = office; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        // Pull request and issue rows of the "Tu turno" sign open in the browser; anything else drags.
        let p = convert(e.locationInWindow, from: nil)
        let at = CGPoint(x: p.x / P, y: p.y / P)
        if let hit = turnRects.first(where: { $0.0.contains(at) }) {
            if let url = URL(string: hit.1), url.scheme == "https" { NSWorkspace.shared.open(url) }
            return
        }
        window?.performDrag(with: e)
    }

    func font(_ size: CGFloat, _ bold: Bool) -> NSFont {
        let key = "\(size)-\(bold)"
        if let f = fonts[key] { return f }
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular); fonts[key] = f; return f
    }

    static let center: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = .center; return p }()
    static let left: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }()
    static let right: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = .right; return p }()

    /// Text that must stay readable at the small size grows a little there.
    var big: CGFloat { P <= 2 ? 1.25 : 1 }

    /// Text at art coordinates. `size` is in points at the medium size (P = 3).
    func text(_ s: String, _ x: Int, _ y: Double, _ w: Int, size: CGFloat, col: UInt32, bold: Bool = false, left: Bool = false, right: Bool = false) {
        guard stat else { return }
        let pt = size * P / 3
        let a: [NSAttributedString.Key: Any] = [.font: font(pt, bold), .foregroundColor: ns(col),
                                                .paragraphStyle: right ? OfficeView.right : (left ? OfficeView.left : OfficeView.center)]
        (s as NSString).draw(in: NSRect(x: CGFloat(x) * P, y: CGFloat(y) * P, width: CGFloat(w) * P, height: pt + 4), withAttributes: a)
    }

    func textWidth(_ s: String, size: CGFloat, bold: Bool) -> Int {
        let pt = size * P / 3
        return Int(((s as NSString).size(withAttributes: [.font: font(pt, bold)]).width / P).rounded(.up))
    }

    // MARK: Frame

    /// Two layers. The room layer holds the background and every text at screen resolution; it is
    /// redrawn only when some text changes. The sprite layer (robots, desks, screens, lights) is drawn
    /// every frame at art resolution, 296 x 164 pixels, and Core Animation scales it up nearest-neighbor.
    var stat = false
    var cacheSig = ""; var cacheKey = ""
    var cache: CGImage?; var sprites: CGImage?
    var spriteCtx: CGContext?
    let room = CALayer(), spriteLayer = CALayer()

    /// Bitmaps use the display's color space so Core Animation can use them without converting.
    var space: CGColorSpace { window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)! }

    func setUpLayers() {
        room.addSublayer(spriteLayer)
        spriteLayer.magnificationFilter = .nearest
        room.cornerRadius = 10; room.masksToBounds = true
        room.backgroundColor = cg(0x1C2230)
        layer = room; wantsLayer = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        room.frame = bounds; spriteLayer.frame = room.bounds
        CATransaction.commit()
    }

    func newContext(_ w: Int, _ h: Int, scale: CGFloat) -> CGContext? {
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: scale, y: -scale)
        c.interpolationQuality = .none
        return c
    }

    /// The lead's "¡tu turno!" sign: how long it has waited, or nil when it is not seated waiting for you.
    func turnSign(_ a: Agent, now: Double) -> String? {
        guard a.act == .idle, let w = office.turnWait(a), case .seated = agentPose(a, now: now) else { return nil }
        return ago(now - w.since)
    }

    func signature(_ s: Sky) -> String {
        let now = Date().timeIntervalSince1970
        var sig = "\(s.key)|\(OfficeView.df.string(from: Date()))|"
        for slot in 0..<6 {
            if let a = office.agents.values.first(where: { $0.slot == slot }) { sig += "\(a.name)|\(a.detail)|\(a.act == .wait)|\(a.act == .idle)|\(a.leaving != nil)|\(turnSign(a, now: now) ?? "")|" } else { sig += "-|" }
        }
        for t in office.turns { sig += "\(t.key)\(t.title)\(t.sub)\(ago(now - t.since))|" }
        sig += "\(office.agents.values.filter { $0.slot < 0 }.count)|"
        let m = office.machines
        sig += "\(m.docker)\(m.dockerStuck)\(m.containers)\(m.devices.map { $0.name + ($0.link ?? "") + $0.kind })\(m.servers.map { "\($0.port)\($0.kind)" })\(m.watchers)|"
        for it in office.board { sig += "\(it.number ?? 0)\(it.title)\(it.stage)\(it.note ?? "")\(it.repo ?? "")|" }
        return sig
    }

    /// Draws the current frame and hands it to the layers.
    func render() {
        let bs = window?.backingScaleFactor ?? 2
        let key = "\(P)-\(bs)-\(space.name.map { $0 as String } ?? "")"
        let hour = Calendar.current.component(.hour, from: Date())
        let s = sky(hour: hour)
        if bg == nil || bgKey != s.key { bg = makeImage(W, H) { drawBackground(s) }; bgKey = s.key; cache = nil }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let sig = signature(s)
        if cache == nil || sig != cacheSig || key != cacheKey,
           let c = newContext(Int(CGFloat(W) * P * bs), Int(CGFloat(H) * P * bs), scale: bs) {
            G.ctx = c; G.P = P
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            stat = true
            if let bg = bg { blit(bg, 0, 0) }
            drawStaticText()
            drawMachineRoom(0); drawBoard(0)
            stat = false
            NSGraphicsContext.restoreGraphicsState()
            cache = c.makeImage(); cacheSig = sig; cacheKey = key
            room.contents = cache; room.contentsScale = bs
        }
        if spriteCtx == nil { spriteCtx = newContext(W, H, scale: 1) }
        if let sc = spriteCtx {
            sc.clear(CGRect(x: 0, y: 0, width: W, height: H))
            G.ctx = sc; G.P = 1
            drawSprites(s)
            sprites = sc.makeImage()
            spriteLayer.contents = sprites
        }
        CATransaction.commit()
    }

    /// The current frame as one image (for snap.png).
    func snapshot() -> CGImage? {
        render()
        guard let cache = cache, let sprites = sprites, let c = newContext(cache.width, cache.height, scale: 1) else { return nil }
        c.scaleBy(x: 1, y: -1); c.translateBy(x: 0, y: -CGFloat(cache.height))
        let r = CGRect(x: 0, y: 0, width: cache.width, height: cache.height)
        c.draw(cache, in: r); c.interpolationQuality = .none; c.draw(sprites, in: r)
        return c.makeImage()
    }

    func drawStaticText() {
        let present = office.agents.values.filter { $0.leaving == nil }
        let active = present.filter { $0.act != .idle }.count
        let now = Date().timeIntervalSince1970
        text("OFICINA DE AGENTES", 45, 7.5, 52, size: 7.5, col: cream, bold: true)
        if !office.turns.isEmpty {
            // Count badge, readable even at the small size.
            px(49, 12, 44, 7, 0x9E2F2F); px(49, 12, 44, 1, 0xC9524A)
            text("Tu turno: \(office.turns.count)", 45, 12.5, 52, size: 6.6 * big, col: 0xFFE58A, bold: true)
        } else {
            text("\(present.count) aquí · \(active) trabajando", 45, 12.8, 52, size: 6, col: 0xA9AEC4)
        }
        text(OfficeView.df.string(from: Date()), 101, 8.6, 16, size: 6.5, col: green, bold: true)
        // Name tags (walkers pass in front of them).
        for slot in 0..<6 {
            let (dx, dy) = deskOrigin(slot)
            if let a = office.agents.values.first(where: { $0.slot == slot }) {
                let col = shade(kindColor[a.kind] ?? 0xB0B6C8, 0.25)
                let nw = min(44, textWidth(a.name, size: 7.5, bold: true) + 4)
                px(dx + 17 - nw / 2, dy + 18, nw, 4, 0x1B1F2C, 0.55)
                text(a.name, dx - 5, Double(dy) + 18.2, 44, size: 7.5, col: col, bold: true)
                if let w = office.turnWait(a), a.act == .idle {
                    text("tu turno · " + ago(now - w.since), dx - 5, Double(dy) + 22.4, 44, size: 6, col: gold, bold: true)
                } else {
                    text(a.detail, dx - 5, Double(dy) + 22.4, 44, size: 6, col: a.act == .wait ? gold : 0xD5D9E6)
                }
                // The lead holds up a "¡tu turno!" sign with the minutes it has waited.
                if let age = turnSign(a, now: now) {
                    let sx = dx - 4, sy = dy - 27
                    px(sx + 1, sy + 1, 24, 9, 0x000000, 0.3)
                    px(sx, sy, 24, 9, 0x5A3A1A); px(sx + 1, sy + 1, 22, 7, 0xFFE58A); px(sx + 1, sy + 1, 22, 1, 0xFFF4C4)
                    text("¡TU TURNO!", sx, Double(sy) + 0.9, 24, size: 6.2 * big, col: 0x9E2F2F, bold: true)
                    text(age, sx, Double(sy) + 4.5, 24, size: 5.4 * big, col: 0x5A3A1A, bold: true)
                }
            } else {
                text("libre", dx - 5, Double(dy) + 19, 44, size: 6.5, col: 0x6B7590)
            }
        }
        let lobby = office.agents.values.filter { $0.slot < 0 }.count
        if lobby > 0 { text("+\(lobby) en el pasillo", 96, 45.5, 50, size: 6, col: cream) }
    }

    func drawSprites(_ s: Sky) {
        let f = frameNo
        let now = Date().timeIntervalSince1970
        drawWindow(s, now: now)
        px(18, 27, 1, 1, (f / 5) % 2 == 0 ? 0xE04848 : 0x5A2020)

        // Who is where.
        var walkers: [(Agent, Int, Int, Double)] = []
        var seated: [Int: Agent] = [:]
        for a in office.agents.values where a.slot >= 0 {
            switch agentPose(a, now: now) {
            case .seated: seated[a.slot] = a
            case let .walking(x, y, t): walkers.append((a, x, y, t))
            case .gone: break
            }
        }
        drawDoor(open: walkers.contains { $0.3 < 0.18 })
        // A waiting agent glows so you notice it from across the room.
        for (slot, a) in seated where a.act == .wait {
            let (dx, dy) = deskOrigin(slot)
            let k: CGFloat = (f / 3) % 2 == 0 ? 0.30 : 0.16
            px(dx - 3, dy - 24, 40, 42, 0xF25C54, k * 0.5); px(dx - 1, dy - 22, 36, 39, 0xF25C54, k * 0.5)
        }
        for (slot, a) in seated where a.act == .idle && office.turnWait(a) != nil {
            let (dx, dy) = deskOrigin(slot)
            let k: CGFloat = (f / 3) % 2 == 0 ? 0.26 : 0.14
            px(dx - 3, dy - 24, 40, 42, gold, k * 0.5); px(dx - 1, dy - 22, 36, 39, gold, k * 0.5)
        }
        // Painter's order: anything whose feet are higher up is drawn first.
        var items: [(key: Int, order: Int, slot: Int, agent: Agent?, x: Int, y: Int, walking: Bool)] = []
        for slot in 0..<6 { items.append((deskOrigin(slot).1, 1, slot, nil, 0, 0, false)) }
        for (slot, a) in seated { let (dx, dy) = deskOrigin(slot); items.append((dy - 1, 0, slot, a, dx + 5, dy - 15, false)) }
        for (a, x, y, _) in walkers { items.append((min(y + 18, deskOrigin(a.slot).1 - 1), 0, a.slot, a, x, y, true)) }
        items.sort { $0.key != $1.key ? $0.key < $1.key : $0.order < $1.order }
        for it in items {
            guard let a = it.agent else { drawDesk(it.slot, seated[it.slot], f); continue }
            let col = kindColor[a.kind] ?? 0xB0B6C8
            if it.walking {
                let leg = [0, 1, 2, 1][Int(now * 9) % 4]
                robot(it.x, it.y, color: col, act: a.leaving != nil ? .done : .idle, f: f, legs: leg, lead: a.kind == "lead")
            } else {
                robot(it.x, it.y, color: col, act: a.act, f: f + a.slot * 5, legs: -1, lead: a.kind == "lead")
            }
        }
        for (slot, a) in seated { let (dx, dy) = deskOrigin(slot); bubble(dx + 16, dy - 23, a.act, f) }
        drawMachineRoom(f)
        drawBoard(f)
    }

    func drawWindow(_ s: Sky, now: Double) {
        let ctx = G.ctx!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 10 * G.P, y: 7 * G.P, width: 26 * G.P, height: 16 * G.P))
        if s.night {
            let stars = [(12, 9), (17, 12), (24, 8), (34, 15), (14, 19), (27, 20), (20, 17)]
            for (i, st) in stars.enumerated() { px(st.0, st.1, 1, 1, (Int(now) + i) % 5 == 0 ? 0x8A93B8 : 0xFFFFFF) }
        } else {
            let c1 = 4 + Int(now / 5) % 40, c2 = 10 + Int(now / 8) % 40
            px(c1, 10, 6, 2, 0xFFFFFF, 0.9); px(c1 + 1, 9, 3, 1, 0xFFFFFF, 0.9)
            px(c2 + 2, 18, 7, 2, 0xFFFFFF, 0.8); px(c2 + 4, 17, 3, 1, 0xFFFFFF, 0.8)
        }
        ctx.restoreGState()
        px(22, 7, 2, 16, 0xD9CBB0); px(10, 14, 26, 1, 0xD9CBB0)
    }

    func drawDoor(open: Bool) {
        if open {
            px(119, 14, 12, 28, 0x14161F); px(119, 14, 12, 3, 0x0E0F16)
            px(119, 14, 2, 28, 0x6A4630); px(121, 15, 1, 26, 0x8A5E3E)
            px(118, 42, 14, 6, 0xFFE9B0, 0.16); px(120, 48, 10, 3, 0xFFE9B0, 0.10)
        } else {
            px(119, 14, 12, 28, 0x8A5E3E); px(119, 14, 12, 1, 0xA0714F)
            px(121, 16, 8, 9, 0x7A5238); px(121, 28, 8, 11, 0x7A5238)
            px(128, 29, 1, 2, gold)
        }
    }

    func drawDesk(_ slot: Int, _ a: Agent?, _ f: Int) {
        let (dx, dy) = deskOrigin(slot)
        if let d = desk { blit(d, dx, dy - 10) }
        guard let a = a else { return }
        monitor(dx + 21, dy - 9, a.act, f + slot * 3)
        let col = kindColor[a.kind] ?? 0xB0B6C8
        let x = dx + 5
        if a.act == .idle, office.turnWait(a) != nil {
            // Raised arm holding the "¡tu turno!" sign (drawn in the room layer), the other hand on the desk.
            let sx = dx - 4, sy = dy - 27
            px(dx + 4, sy + 9, 1, 2, 0x7A5238)
            px(dx + 3, dy - 16, 3, 2, shade(col, 0.2)); px(dx + 3, dy - 14, 2, 11, col); px(dx + 4, dy - 14, 1, 11, shade(col, -0.25))
            px(x + 10, dy, 2, 3, col)
            let edge: UInt32 = (f / 3) % 2 == 0 ? 0xFF8A3D : gold
            px(sx - 1, sy - 1, 26, 1, edge); px(sx - 1, sy + 9, 26, 1, edge); px(sx - 1, sy, 1, 9, edge); px(sx + 24, sy, 1, 9, edge)
            return
        }
        switch a.act {
        case .type, .write, .delegate:
            let bob = (f / 2) % 2
            px(x + 1, dy, 2, 3 + bob, col); px(x + 9, dy, 2, 4 - bob, col)
            px(x + 1, dy + 3 + bob, 2, 1, shade(col, -0.3)); px(x + 9, dy + 4 - bob, 2, 1, shade(col, -0.3))
        case .idle:
            px(x, dy, 2, 3, col); px(x + 10, dy, 2, 3, col)
            px(dx + 1, dy + 3, 3, 3, cream); px(dx + 4, dy + 4, 1, 1, cream); px(dx + 1, dy + 3, 3, 1, 0x7A5238)
            px(dx + 2, dy - (f / 4) % 2 - 1, 1, 2, 0xC9CEDF, 0.8)
        case .wait:
            let up = (f / 3) % 2
            px(x - 1, dy - 9 - up, 2, 6, col); px(x - 2, dy - 11 - up, 3, 2, col)
            px(x + 10, dy, 2, 3, col)
        default:
            px(x + 1, dy, 2, 3, col); px(x + 9, dy, 2, 3, col)
        }
    }

    func monitor(_ x: Int, _ y: Int, _ a: Act, _ f: Int) {
        switch a {
        case .type, .delegate:
            px(x, y, 10, 7, 0x0F2A1A)
            for r in 0..<3 { let w = 3 + ((f + r * 3) * 7) % 6; px(x + 1, y + 1 + r * 2, w, 1, green) }
        case .read: px(x, y, 10, 7, cream); for r in 0..<3 { px(x + 1, y + 1 + r * 2, 8 - (r + f / 6) % 3, 1, 0x8A93A6) }
        case .write: px(x, y, 10, 7, cream); px(x + 1, y + 1, 6, 1, 0x4F8FE0); px(x + 1, y + 3, 7, 1, 0x8A93A6); px(x + 1, y + 5, (f / 2) % 8 + 1, 1, 0xE07A4F)
        case .browse: px(x, y, 10, 7, 0x2B4C7E); px(x, y, 10, 1, 0x8A93A6); px(x + 1, y + 2, 8, 1, skyBlue); px(x + 1, y + 4, 4, 2, gold); px(x + 6, y + 4, 3, 1, 0xC9CEDF)
        case .talk: px(x, y, 10, 7, 0x3B1E4A); px(x + 1, y + 1 + (f / 3) % 3, 6, 1, 0xE0A3F2); px(x + 3, y + 4, 6, 1, 0xB07FD6)
        case .wait: px(x, y, 10, 7, (f / 3) % 2 == 0 ? 0x7A2A2A : 0x3A1515); px(x + 4, y + 1, 2, 3, gold); px(x + 4, y + 5, 2, 1, gold)
        case .think: px(x, y, 10, 7, 0x1B2440); px(x + 2 + (f / 3) % 6, y + 3, 2, 2, skyBlue)
        case .done: px(x, y, 10, 7, 0x0F2A1A); px(x + 3, y + 3, 1, 1, green); px(x + 4, y + 4, 1, 1, green); px(x + 5, y + 3, 1, 1, green); px(x + 6, y + 2, 1, 1, green)
        case .idle: px(x, y, 10, 7, 0x10111A); px(x + (f / 8) % 9, y + (f / 5) % 6, 1, 1, 0x4F8FE0)
        }
    }

    /// Original boxy robot seen from above-front: antenna, top of the head, screen face, square body.
    /// legs: -1 seated (lower body hidden by the desk), 0/1/2 walk frames.
    func robot(_ x: Int, _ y: Int, color: UInt32, act: Act, f: Int, legs: Int, lead: Bool = false) {
        let top = shade(color, 0.28), side = shade(color, -0.25)
        if legs >= 0 { px(x + 1, y + 17, 10, 2, 0x000000, 0.25) }
        px(x + 5, y - 2, 1, 2, 0x2A2D3A)
        px(x + 4, y - 3, 3, 1, (f / 6) % 2 == 0 && act != .idle && act != .done ? gold : 0x8A93A6)
        // Head: top face (3/4 view), front with a screen face.
        px(x, y, 12, 2, top); px(x, y, 12, 1, shade(color, 0.45))
        if lead { px(x + 1, y + 1, 10, 1, gold) }
        px(x, y + 2, 12, 7, color); px(x + 11, y + 2, 1, 7, side); px(x, y + 8, 12, 1, side)
        if lead { px(x, y + 2, 12, 1, gold) }
        px(x + 1, y + 3, 10, 5, ink)
        eyes(x, y, act, f)
        // Body.
        px(x + 1, y + 9, 10, 7, color); px(x + 1, y + 9, 10, 1, side); px(x + 10, y + 9, 1, 7, side)
        px(x + 4, y + 11, 4, 2, ink); px(x + 5, y + 11, 1, 1, act == .wait ? red : green)
        if legs >= 0 {
            let swing = legs == 0 ? 1 : (legs == 2 ? -1 : 0)
            px(x, y + 10 + swing, 1, 4, side); px(x + 11, y + 10 - swing, 1, 4, side)
            let l = legs == 0 ? 3 : 2, r = legs == 2 ? 3 : 2
            px(x + 3, y + 16, 2, l, ink); px(x + 7, y + 16, 2, r, ink)
        } else {
            px(x, y + 10, 1, 5, side); px(x + 11, y + 10, 1, 5, side)
        }
    }

    func eyes(_ x: Int, _ y: Int, _ act: Act, _ f: Int) {
        let blink = f % 37 == 0
        switch act {
        case .idle: px(x + 3, y + 5, 2, 1, skyBlue); px(x + 7, y + 5, 2, 1, skyBlue)
        case .done:
            px(x + 2, y + 5, 1, 1, green); px(x + 3, y + 4, 1, 1, green); px(x + 4, y + 5, 1, 1, green)
            px(x + 7, y + 5, 1, 1, green); px(x + 8, y + 4, 1, 1, green); px(x + 9, y + 5, 1, 1, green)
        case .wait: px(x + 3, y + 4, 2, 3, gold); px(x + 7, y + 4, 2, 3, gold)
        case .think: px(x + 4, y + 4, 2, 1, skyBlue); px(x + 8, y + 4, 2, 1, skyBlue)
        default:
            let look = (act == .read || act == .browse) ? (f / 8) % 2 : 0
            if blink { px(x + 3 + look, y + 5, 2, 1, skyBlue); px(x + 7 + look, y + 5, 2, 1, skyBlue) }
            else { px(x + 3 + look, y + 4, 2, 2, skyBlue); px(x + 7 + look, y + 4, 2, 2, skyBlue) }
        }
    }

    func bubble(_ bx: Int, _ by: Int, _ a: Act, _ f: Int) {
        func box(_ w: Int) {
            px(bx, by + 1, w, 4, cream); px(bx + 1, by, w - 2, 6, cream)
            px(bx + 1, by + 6, 2, 1, cream); px(bx, by + 7, 1, 1, cream)
        }
        switch a {
        case .think: box(9); for i in 0..<3 where (f / 3) % 4 > i { px(bx + 2 + i * 2, by + 3, 1, 1, 0x2E3247) }
        case .wait:
            let b = by - 3 - (f / 3) % 2
            px(bx, b + 1, 7, 8, red); px(bx + 1, b, 5, 10, red); px(bx + 1, b + 10, 2, 1, red); px(bx, b + 11, 1, 1, red)
            px(bx + 3, b + 2, 1, 4, 0xFFFFFF); px(bx + 3, b + 7, 1, 1, 0xFFFFFF)
            if (f / 3) % 2 == 0 { px(bx - 1, b + 1, 1, 8, 0xFFB3B3, 0.7); px(bx + 7, b + 1, 1, 8, 0xFFB3B3, 0.7) }
        case .talk: box(9); px(bx + 2, by + 2, 6, 1, 0x9B6FD6); px(bx + 2, by + 4, 3 + (f / 3) % 3, 1, 0x9B6FD6)
        case .delegate: box(8); px(bx + 2, by + 2, 2, 2, 0x4FB477); px(bx + 5, by + 2, 2, 2, 0x4F8FE0); px(bx + 4, by + 3, 1, 1, 0x2E3247)
        case .done: box(7); px(bx + 2, by + 3, 1, 1, 0x4FB477); px(bx + 3, by + 4, 1, 1, 0x4FB477); px(bx + 4, by + 3, 1, 1, 0x4FB477); px(bx + 5, by + 2, 1, 1, 0x4FB477)
        default: break
        }
    }

    // MARK: Machine room

    func drawMachineRoom(_ f: Int) {
        let m = office.machines
        let live = !stat
        text("SALA DE MÁQUINAS", 152, 4.4, 57, size: 5.8, col: 0x8A93A6, bold: true)
        // Docker rack: one blinking light per container.
        let shown = Array(m.containers.prefix(7))
        let head = !m.docker ? "docker apagado" : (m.dockerStuck ? "docker no responde" : "docker")
        text(head, 172, 10.5, 39, size: 5.5, col: !m.docker ? 0x6B7590 : (m.dockerStuck ? gold : green), bold: true, left: true)
        for i in 0..<7 {
            let y = 16 + i * 5
            if m.docker && i < shown.count {
                text(shown[i], 172, Double(y), 39, size: 5.2, col: 0xD5D9E6, left: true)
                if live {
                    let on = (f / (2 + i % 3) + i) % 4 != 0
                    px(155, y + 1, 2, 2, on ? green : 0x2E5E3C)
                    px(158, y + 1, 1, 1, (f / (3 + i)) % 3 == 0 ? gold : 0x5A4A20)
                }
            } else if stat {
                px(155, y + 1, 2, 2, m.docker ? 0x2A3A30 : 0x2A1C1C)
            }
        }
        if m.containers.count > 7 { text("+\(m.containers.count - 7) más", 172, 50.5, 39, size: 5, col: 0xA9AEC4, left: true) }
        else if m.docker && !m.dockerStuck && m.containers.isEmpty { text("sin contenedores", 172, 16, 39, size: 5, col: 0x8A93A6, left: true) }

        // Phones and simulators on stands.
        let devs = Array(m.devices.prefix(3))
        if devs.isEmpty { text("sin teléfonos", 151, 58, 59, size: 5.5, col: 0x8A93A6) }
        for (i, d) in devs.enumerated() {
            let cx = devs.count == 1 ? 180 : (devs.count == 2 ? 167 + i * 26 : 161 + i * 19)
            let ios = d.kind == "ios"
            if stat {
                px(cx - 3, 64, 7, 3, 0x2A2F3D); px(cx - 2, 63, 5, 1, 0x3A4052)
                px(cx - 3, 50, 8, 14, 0x000000, 0.2)
                px(cx - 4, 49, 8, 14, ios ? 0xD8DCE6 : 0x3E9E5B); px(cx - 4, 49, 8, 1, ios ? 0xF2F4F8 : 0x6FCF8E)
                let w = devs.count == 1 ? 50 : (devs.count == 2 ? 26 : 20)
                text(d.name, cx - w / 2, 79, w, size: 5, col: cream, bold: true)
                text(d.link ?? (ios ? "simulador" : "android"), cx - w / 2, 83, w, size: 4.6, col: ios ? 0xC9CEDF : 0x8FE0A8)
            } else {
                px(cx - 3, 51, 6, 10, ios ? 0x1B2440 : 0x0F2A1A)
                if ios {
                    px(cx - 1, 51, 2, 1, ink)
                    let apps: [UInt32] = [0x4F8FE0, 0xE07A4F, 0x4FB477, gold, 0x9B6FD6, 0xE04848]
                    for k in 0..<6 { px(cx - 2 + (k % 2) * 3, 53 + (k / 2) * 2, 2, 1, apps[(k + f / 12) % 6]) }
                } else {
                    for r in 0..<4 { px(cx - 2, 52 + r * 2, 1 + ((f / 2 + r * 3 + i) * 5) % 4, 1, green) }
                    px(cx - 1, 62, 2, 1, 0x1B4A2A)
                }
            }
        }
        if m.devices.count > 3 { text("+\(m.devices.count - 3)", 196, 66.5, 14, size: 5, col: cream) }

        // Local servers: one little screen per port.
        let svs = Array(m.servers.prefix(4))
        if svs.isEmpty { text("sin servidores", 151, 106, 59, size: 5.5, col: 0x6B7590) }
        for (i, s) in svs.enumerated() {
            let y = 96 + i * 8
            if live {
                px(154, y, 10, 6, 0x0F2A1A); px(154, y, 10, 1, 0x2A3A30)
                for r in 0..<2 { px(155, y + 2 + r * 2, 2 + ((f + i * 5 + r * 3) * 3) % 7, 1, r == 0 ? green : 0x4FB477) }
            } else {
                text("\(s.port)", 166, Double(y) - 0.2, 16, size: 5.3, col: gold, bold: true, left: true)
                text(s.kind, 177, Double(y) - 0.2, 32, size: 5.3, col: 0xD5D9E6, left: true)
                px(155, y + 6, 54, 1, 0x232736)
            }
        }
        if m.servers.count > 4 { text("+\(m.servers.count - 4) más", 166, 125.3, 40, size: 4.8, col: 0xA9AEC4, left: true) }

        // Watchers with binoculars.
        let ws = Array(m.watchers.prefix(2))
        for (i, w) in ws.enumerated() {
            let x = ws.count == 1 ? 174 : 160 + i * 26, y = 134
            text("vigía " + w, x - 8, 153.5, 28, size: 5.3, col: 0xD5D9E6, bold: true)
            guard live else { continue }
            robot(x, y, color: kindColor["watcher"]!, act: .read, f: f + i * 7, legs: 1)
            px(x + 2, y + 4, 3, 2, ink); px(x + 7, y + 4, 3, 2, ink); px(x + 5, y + 4, 2, 1, 0x3A3F55)
            px(x + 3, y + 4, 1, 1, (f / 6 + i) % 2 == 0 ? skyBlue : 0x4A5570)
        }
        if m.watchers.count > 2 { text("+\(m.watchers.count - 2)", 198, 146, 12, size: 5.5, col: cream) }
    }

    // MARK: Board

    static let stages: [String: (String, UInt32)] = [
        "comments": ("comentarios", 0xD99A1E), "ci_red": ("CI en rojo", 0xD64F4F), "changes": ("piden cambios", 0xD64F4F),
        "ci_running": ("CI corriendo", 0x3D86C6), "approval": ("esperando aprobación", 0x7A8094), "ready": ("listo para mezclar", 0x2F9E5A),
        "draft": ("borrador", 0x8A8FA3), "merged": ("mezclado", 0x4F8F5F), "waiting": ("esperando", 0xB060C8), "working": ("en curso", 0x4F8FE0),
    ]

    static let turnColors: [String: UInt32] = ["done": 0xC8801A, "perm": 0xD64F4F, "ask": 0x9B4FC8, "pr": 0x3D86C6, "issue": 0x2F9E5A]
    /// Clickable rows of the "Tu turno" sign, in art pixels, with the URL they open.
    var turnRects: [(CGRect, String)] = []

    /// A small bell: still and grey when nothing waits, ringing in gold otherwise.
    func bell(_ x: Int, _ y: Int, ringing: Bool, f: Int) {
        if ringing == stat { return }   // the still bell lives in the room layer, the ringing one in the sprites
        let sw = ringing ? ((f / 3) % 2 == 0 ? -1 : 1) : 0
        let c: UInt32 = ringing ? gold : 0x9AA0B4
        px(x + 2 + sw, y - 1, 1, 1, c); px(x + 1 + sw, y, 3, 3, c); px(x + sw, y + 3, 5, 1, c)
        px(x + 2, y + 4, 1, 1, ringing ? 0xFFF1D0 : c)
        if ringing && (f / 3) % 2 == 0 { px(x - 2, y, 1, 3, 0xFFF1D0); px(x + 6, y, 1, 3, 0xFFF1D0) }
    }

    /// "Tu turno" sign on top of the board: everything that needs you, oldest first, with how long it
    /// has waited. Returns the first free row below it.
    func drawTurns(_ f: Int) -> Int {
        let bx = 216, bw = 74, ts = office.turns, on = !ts.isEmpty
        let now = Date().timeIntervalSince1970
        if stat {
            turnRects = []
            px(bx + 2, 6, bw - 3, 10, 0x000000, 0.25)
            px(bx + 1, 5, bw - 3, 10, on ? 0x9E2F2F : 0x4A4F60); px(bx + 1, 5, bw - 3, 1, on ? 0xC9524A : 0x5E6478); px(bx + 1, 14, bw - 3, 1, on ? 0x7A2020 : 0x3A3F4E)
        }
        text("TU TURNO", bx + 13, 6.4, 40, size: 8 * big, col: on ? 0xFFF1D0 : 0xC3C8D6, bold: true, left: true)
        if on {
            if stat { px(bx + bw - 14, 6, 11, 8, gold); px(bx + bw - 14, 6, 11, 1, 0xFFE08A) }
            text("\(ts.count)", bx + bw - 14, 7.0, 11, size: 8 * big, col: 0x3A2A1C, bold: true)
        } else {
            text("nada pendiente", bx + 36, 7.9, bw - 40, size: 5.6 * big, col: 0xC3C8D6, right: true)
        }
        bell(bx + 3, 7, ringing: on, f: f)
        guard on else { return 16 }
        let rowH = 11, top = 17, maxRows = 5
        let rows = ts.count > maxRows ? maxRows - 1 : ts.count
        for (i, t) in ts.prefix(rows).enumerated() {
            let y = top + i * rowH
            let col = OfficeView.turnColors[t.kind] ?? 0x7A8094
            if !stat {
                // Permissions and questions block a session: their tab blinks.
                if t.kind == "perm" || t.kind == "ask" { px(bx + 2, y, 2, rowH - 1, (f / 3) % 2 == 0 ? 0xFF3030 : col) }
                continue
            }
            px(bx + 3, y + 1, bw - 5, rowH - 1, 0x000000, 0.2)
            px(bx + 2, y, bw - 5, rowH - 1, 0xFFF3C4); px(bx + 2, y, bw - 5, 1, 0xFFF9E0)
            px(bx + 2, y, 2, rowH - 1, col)
            let age = ago(now - t.since)
            let aw = textWidth(age, size: 5.4 * big, bold: false) + 1
            text(t.title, bx + 6, Double(y) + 0.6, bw - 11 - aw, size: 6.4 * big, col: 0x2E3247, bold: true, left: true)
            text(age, bx + bw - 5 - aw, Double(y) + 1.0, aw, size: 5.4 * big, col: 0x7A6A50, right: true)
            text(t.sub + (t.url != nil ? "  ›" : ""), bx + 6, Double(y) + 5.3, bw - 11, size: 5.8 * big, col: shade(col, -0.25), left: true)
            if let u = t.url { turnRects.append((CGRect(x: bx + 2, y: y, width: bw - 5, height: rowH - 1), u)) }
        }
        var end = top + rows * rowH
        if ts.count > rows { text("+\(ts.count - rows) más", bx, Double(end) - 0.4, bw, size: 6 * big, col: 0x3A2A1C, bold: true); end += 6 }
        return end + 1
    }

    /// Cork board: the "Tu turno" sign, then the pull requests and tasks from board.json.
    func drawBoard(_ f: Int) {
        let bx = 216, bw = 74
        let ph = drawTurns(f) + 2
        if stat { px(236, ph, 34, 8, cream); px(236, ph + 8, 34, 1, 0x000000, 0.2); px(252, ph, 2, 2, red) }
        text("PIZARRA", 236, Double(ph) + 1.6, 34, size: 7.5, col: 0x3A2A1C, bold: true)
        let items = office.board
        if items.isEmpty { text("sin PRs ni tareas", bx, Double(ph) + 14, bw, size: 6.5, col: 0x5A4A3A); return }
        let rowH = 8, top = ph + 12, maxRows = max(1, (H - top - 8) / rowH)
        let rows = items.count > maxRows ? maxRows - 1 : maxRows
        for (i, it) in items.prefix(rows).enumerated() {
            let y = top + i * rowH
            let (label, col) = OfficeView.stages[it.stage] ?? (it.stage, 0x7A8094)
            let urgent = it.stage == "comments" || it.stage == "ci_red"
            if !stat {
                // Rows that need you blink their tab.
                if urgent { px(bx + 2, y, 2, rowH - 1, (f / 4) % 2 == 0 ? 0xFF3030 : col) }
                continue
            }
            px(bx + 3, y + 1, bw - 5, rowH - 1, 0x000000, 0.18)
            px(bx + 2, y, bw - 5, rowH - 1, urgent ? 0xFFF4D6 : (it.stage == "merged" ? 0xE6E2D6 : cream))
            px(bx + 2, y, 2, rowH - 1, col)
            px(bx + 8 + (i * 13) % (bw - 20), y - 1, 2, 2, i % 3 == 0 ? red : (i % 3 == 1 ? 0x4F8FE0 : 0x4FB477))
            let id = it.number.map { "#\($0) " } ?? ""
            let repo = it.repo ?? ""
            let title = it.title.replacingOccurrences(of: #"^\w+\(([A-Z]+-\d+)\): "#, with: "$1 ", options: .regularExpression)
            text(id + title, bx + 5, Double(y) + 0.3, bw - 9, size: 6.2, col: 0x2E3247, bold: true, left: true)
            let note = it.note.map { $0.isEmpty ? "" : " · " + $0 } ?? ""
            text(label + note + (repo.isEmpty ? "" : "  " + repo), bx + 5, Double(y) + 3.7, bw - 9, size: 5.6, col: col, left: true)
        }
        if items.count > rows { text("+\(items.count - rows) más", bx, Double(top + rows * rowH) + 0.5, bw, size: 6.2, col: 0x3A2A1C, bold: true) }
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let office = Office(); let feed = Feed(); let probe = Probe()
    var panel: NSPanel!; var view: OfficeView!
    var timer: Timer?; var rate = 0.0; var tick = 0
    var lastProbe = 0.0

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = feed.read(into: office, replay: true)
        // What already waited before the app opened is shown, not announced.
        office.turns = office.computeTurns()
        notified.formUnion(office.turns.map { $0.key })
        view = OfficeView(office: office)
        var scale = CGFloat(UserDefaults.standard.double(forKey: "scale").nonZero ?? 3)
        if ![2, 3, 4].contains(scale) { scale = 3 }
        view.P = scale
        let size = NSSize(width: CGFloat(W) * scale, height: CGFloat(H) * scale)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        view.setUpLayers()
        panel.contentView = view
        if panel.setFrameUsingName("AgentOffice") {
            // The saved frame may come from an older layout: keep its top-left corner, use the new size.
            var fr = panel.frame; let top = fr.maxY
            fr.size = size; fr.origin.y = top - size.height
            panel.setFrame(fr, display: false)
        } else if let s = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: s.maxX - size.width - 20, y: s.minY + 20))
        }
        panel.setFrameAutosaveName("AgentOffice")
        let menu = NSMenu()
        for (t, s) in [("Pequeño", 2.0), ("Mediano", 3.0), ("Grande", 4.0)] {
            let it = NSMenuItem(title: t, action: #selector(resize(_:)), keyEquivalent: ""); it.target = self; it.tag = Int(s); menu.addItem(it)
        }
        menu.addItem(.separator())
        let n = NSMenuItem(title: "Avisos con sonido", action: #selector(toggleNotify(_:)), keyEquivalent: "")
        n.target = self; n.state = notifyOn ? .on : .off; menu.addItem(n)
        menu.addItem(.separator())
        let h = NSMenuItem(title: "Ocultar la oficina", action: #selector(toggleOffice), keyEquivalent: ""); h.target = self; menu.addItem(h)
        let q = NSMenuItem(title: "Cerrar la oficina", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(q)
        view.menu = menu
        setUpStatusItem(menu)
        if !UserDefaults.standard.bool(forKey: "hidden") { panel.orderFrontRegardless() }
        readBoard(); pollMachines()
        view.render()
        schedule(0.16)
    }

    // MARK: Menu bar

    /// Left click shows or hides the office; right click opens the same menu as the office.
    /// The icon carries the "Tu turno" count, so it still tells you when something waits while hidden.
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var lastBadge = -1

    func setUpStatusItem(_ menu: NSMenu) {
        statusMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "building.2", accessibilityDescription: "Agent Office")
        img?.isTemplate = true
        b.image = img; b.imagePosition = .imageLeading
        b.toolTip = "Agent Office: clic para mostrar u ocultar, clic derecho para el menú"
        b.target = self; b.action = #selector(statusClicked(_:))
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateBadge()
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleOffice()
        }
    }

    @objc func toggleOffice() {
        let show = !panel.isVisible
        if show { panel.orderFrontRegardless(); view.render() } else { panel.orderOut(nil) }
        UserDefaults.standard.set(!show, forKey: "hidden")
        statusMenu.items.first { $0.action == #selector(toggleOffice) }?.title = show ? "Ocultar la oficina" : "Mostrar la oficina"
    }

    func updateBadge() {
        let n = office.turns.count
        guard n != lastBadge, let b = statusItem?.button else { return }
        lastBadge = n
        if n > 0 {
            b.attributedTitle = NSAttributedString(string: " \(n)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.systemOrange])
        } else {
            b.title = ""
        }
    }

    @objc func resize(_ s: NSMenuItem) {
        let p = CGFloat(s.tag); view.P = p; UserDefaults.standard.set(Double(p), forKey: "scale")
        var fr = panel.frame; let top = fr.maxY
        fr.size = NSSize(width: CGFloat(W) * p, height: CGFloat(H) * p); fr.origin.y = top - fr.height
        panel.setFrame(fr, display: true)
        view.render()
    }

    /// 12 fps while someone walks, 6 fps while someone works, 1 fps when the office is quiet.
    func schedule(_ interval: Double) {
        rate = interval; timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.step() }
        timer?.tolerance = interval * 0.2
    }

    func step() {
        tick += 1
        let now = Date().timeIntervalSince1970
        let changed = feed.read(into: office, replay: false)
        if tick % (rate < 0.5 ? 30 : 5) == 0 { readBoard() }
        if now - lastBoardRun > 120 { runBoardScript() }
        if now - lastProbe > 10 { pollMachines() }
        office.prune(now: now)
        office.turns = office.computeTurns()
        announce()
        updateBadge()
        view.frameNo += rate < 0.5 ? 1 : 6
        if panel.occlusionState.contains(.visible) { view.render() }
        snapshotIfRequested()
        let want = office.walking(now: now) ? 0.08 : (office.busy || changed ? 0.16 : 1.0)
        if want != rate { schedule(want) }
    }

    var lastBoardRun = 0.0
    var boardRunning = false

    func readBoard() {
        guard let d = FileManager.default.contents(atPath: baseDir + "/board.json"),
              let b = try? JSONDecoder().decode(Board.self, from: d) else { return }
        office.board = b.items
        office.boardUpdated = b.updated ?? 0
        if let y = b.yours {
            office.yours = y
            // The first GitHub list after launch is the baseline: only later arrivals are announced.
            if !boardSeen { boardSeen = true; notified.formUnion(office.computeTurns().filter { $0.url != nil || $0.kind == "pr" || $0.kind == "issue" }.map { $0.key }) }
        }
    }

    // MARK: Notifications

    var notified = Set<String>()
    var pendingNotes: [String] = []
    var noteScheduled = false
    var boardSeen = false
    var notifyOn: Bool { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }

    @objc func toggleNotify(_ s: NSMenuItem) {
        let v = !notifyOn; UserDefaults.standard.set(v, forKey: "notify"); s.state = v ? .on : .off
    }

    /// Each item is announced once, when it enters the list. Items that arrive within 5 s go out
    /// together, and the ones already solved by then are dropped.
    func announce() {
        for t in office.turns where !notified.contains(t.key) { notified.insert(t.key); pendingNotes.append(t.key) }
        guard !pendingNotes.isEmpty, !noteScheduled else { return }
        noteScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.flushNotes() }
    }

    func flushNotes() {
        noteScheduled = false
        let keys = Set(pendingNotes); pendingNotes = []
        let ts = office.turns.filter { keys.contains($0.key) }
        guard notifyOn, !ts.isEmpty else { return }
        let title = ts.count == 1 ? "Tu turno" : "Tu turno: \(ts.count) cosas"
        let body = ts.count == 1 ? ts[0].title + " · " + ts[0].sub : ts.map { $0.title }.joined(separator: " · ")
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(String(body.prefix(220))))\" with title \"Agent Office\" subtitle \"\(esc(title))\" sound name \"Glass\""
        let log = env["AGENT_OFFICE_NOTIFY_LOG"]
        DispatchQueue.global(qos: .utility).async {
            if let log = log {   // demos and tests: write the notification instead of showing it
                let line = Data((script + "\n").utf8)
                if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(line); try? h.close() }
                else { FileManager.default.createFile(atPath: log, contents: line) }
                return
            }
            _ = run("/usr/bin/osascript", ["-e", script], timeout: 5)
        }
    }

    /// board.sh calls the GitHub CLI, so it runs off the main thread and at most every 2 minutes.
    func runBoardScript() {
        lastBoardRun = Date().timeIntervalSince1970
        let script = baseDir + "/board.sh"
        guard !boardRunning, FileManager.default.isExecutableFile(atPath: script) else { return }
        boardRunning = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-lc", "\"\(script)\""]
            var e = env; e["AGENT_OFFICE_DIR"] = baseDir; p.environment = e
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self.boardRunning = false; self.readBoard() }
        }
    }

    /// Machine room probes run on a background queue, at most one at a time, every ~10 s.
    func pollMachines() {
        lastProbe = Date().timeIntervalSince1970
        guard !probe.busy else { return }
        probe.busy = true
        probe.queue.async {
            let m = self.probe.collect()
            DispatchQueue.main.async { self.office.machines = m; self.probe.busy = false }
        }
    }

    /// Touch $AGENT_OFFICE_DIR/snap.request to get the current frame as snap.png (no screen-recording permission needed).
    func snapshotIfRequested() {
        let req = baseDir + "/snap.request"
        guard FileManager.default.fileExists(atPath: req) else { return }
        try? FileManager.default.removeItem(atPath: req)
        guard let img = view.snapshot() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: baseDir + "/snap.png"))
    }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
