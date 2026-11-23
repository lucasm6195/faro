import Darwin
import Foundation

/// Un proceso de la cadena de padres de un servidor.
public struct ProcessNode: Hashable, Sendable {
    public var pid: Int32
    public var name: String
    public var arguments: [String]

    public init(pid: Int32, name: String, arguments: [String]) {
        self.pid = pid
        self.name = name
        self.arguments = arguments
    }

    /// La herramienta de IA que es este proceso, si lo es (`claude`, `node …/codex`…).
    public var agent: AIAgent? {
        if let agent = AIAgent.detect(command: name) { return agent }
        for arg in arguments.prefix(2) {
            if let agent = AIAgent.detect(command: arg) { return agent }
        }
        return nil
    }
}

/// Un proceso tuyo que escucha conexiones en un puerto TCP (por ejemplo `localhost:3000`).
public struct ListeningPort: Identifiable, Hashable, Sendable {
    public var port: Int
    public var pid: Int32
    public var name: String
    public var arguments: [String]
    public var executable: String
    public var directory: String?
    public var started: Date?
    /// Solo acepta conexiones desde este Mac (127.0.0.1 / ::1).
    public var localOnly: Bool
    /// Padres, del más cercano al más lejano.
    public var parents: [ProcessNode]

    public var id: String { "\(pid):\(port)" }

    public init(port: Int, pid: Int32, name: String, arguments: [String], executable: String, directory: String? = nil,
                started: Date? = nil, localOnly: Bool = true, parents: [ProcessNode] = []) {
        self.port = port
        self.pid = pid
        self.name = name
        self.arguments = arguments
        self.executable = executable
        self.directory = directory
        self.started = started
        self.localOnly = localOnly
        self.parents = parents
    }

    /// «Next.js», «Vite», «PostgreSQL»…, o el nombre del proceso.
    public var label: String { ServerKind.label(name: name, arguments: arguments) ?? name }

    /// Proceso de una app o del sistema (Spotify, AirPlay, Docker…), no un servidor de desarrollo.
    public var isApp: Bool {
        let path = executable
        // Python y otros lenguajes se instalan como «Python.app» dentro de un .framework: no son apps.
        if path.contains(".framework/") { return false }
        return path.contains(".app/") || ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains(where: path.hasPrefix)
    }

    /// La IA que lo dejó en marcha, si viene de una.
    public var launchedBy: AIAgent? { parents.lazy.compactMap(\.agent).first }

    /// Proceso que hay que cerrar para apagar el servidor entero: sube por los padres mientras
    /// sean envoltorios (`npm run dev`, `pnpm`, `turbo`…) o el mismo servidor (`next dev` →
    /// `next-server`), y se para en la shell o en la IA que lo lanzó.
    public var root: Int32 {
        var top = pid
        let mine = ServerKind.label(name: name, arguments: arguments)
        for parent in parents {
            if parent.agent != nil || parent.pid <= 1 { break }
            if ServerKind.isWrapper(parent) { top = parent.pid; continue }
            if ServerKind.isShell(parent.name) { break }
            let same = mine != nil && ServerKind.label(name: parent.name, arguments: parent.arguments) == mine
            guard same else { break }
            top = parent.pid
        }
        return top
    }

    /// `http://localhost:3000`
    public var url: URL { URL(string: "http://localhost:\(port)")! }
}

public enum ServerKind {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "login", "launchd", "tmux", "screen"]
    static let wrappers: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "turbo", "nodemon", "concurrently", "tsx", "ts-node",
        "npm-cli.js", "npx-cli.js", "yarn.js", "yarn.cjs", "pnpm.cjs", "pnpm.js", "nx", "vercel", "netlify", "air", "watchexec", "cargo-watch",
    ]

    static func isShell(_ name: String) -> Bool { shells.contains(base(name).trimmingCharacters(in: CharacterSet(charactersIn: "-"))) }

    static func isWrapper(_ node: ProcessNode) -> Bool {
        wrappers.contains(base(node.name)) || node.arguments.prefix(2).contains { wrappers.contains(base($0)) }
    }

    private static func base(_ s: String) -> String {
        (s.split(separator: " ").first.map(String.init) ?? s).split(separator: "/").last.map { $0.lowercased() } ?? ""
    }

    /// Qué es un servidor a partir de su nombre y argumentos.
    public static func label(name: String, arguments: [String]) -> String? {
        let words = ([name] + arguments).flatMap { $0.split(separator: " ") }.map { base(String($0)) }
        let set = Set(words)
        let joined = words.joined(separator: " ")
        let rules: [(String, (Set<String>, String) -> Bool)] = [
            ("Next.js", { s, j in s.contains("next") || j.contains("next-server") || j.contains("next-router-worker") }),
            ("Vite", { s, _ in s.contains("vite") }),
            ("Astro", { s, _ in s.contains("astro") }),
            ("Nuxt", { s, _ in s.contains("nuxt") || s.contains("nuxi") }),
            ("Remix", { s, _ in s.contains("remix") || s.contains("react-router") }),
            ("SvelteKit", { s, _ in s.contains("svelte-kit") }),
            ("Expo", { s, _ in s.contains("expo") || s.contains("metro") }),
            ("Storybook", { s, _ in s.contains("storybook") }),
            ("Wrangler", { s, _ in s.contains("wrangler") || s.contains("workerd") }),
            ("Webpack", { s, _ in s.contains("webpack") || s.contains("webpack-dev-server") }),
            ("Prisma Studio", { _, j in j.contains("prisma studio") }),
            ("Supabase", { s, _ in s.contains("supabase") }),
            ("Firebase", { s, _ in s.contains("firebase") }),
            ("FiveM", { s, _ in s.contains("fxserver") }),
            ("PostgreSQL", { s, _ in s.contains("postgres") || s.contains("postmaster") }),
            ("Redis", { s, _ in s.contains("redis-server") }),
            ("MySQL", { s, _ in s.contains("mysqld") }),
            ("MariaDB", { s, _ in s.contains("mariadbd") }),
            ("MongoDB", { s, _ in s.contains("mongod") }),
            ("Ollama", { s, _ in s.contains("ollama") }),
            ("Docker", { s, _ in s.contains("com.docker.backend") || s.contains("vpnkit") || s.contains("com.docker.vpnkit") }),
            ("Rails", { s, _ in s.contains("rails") || s.contains("puma") }),
            ("Django", { s, j in s.contains("manage.py") && j.contains("runserver") }),
            ("Uvicorn", { s, _ in s.contains("uvicorn") || s.contains("fastapi") }),
            ("Flask", { s, _ in s.contains("flask") }),
            ("Python http.server", { _, j in j.contains("http.server") }),
            ("Jupyter", { s, _ in s.contains("jupyter-lab") || s.contains("jupyter-notebook") || s.contains("jupyter") }),
            ("PHP", { s, _ in s.contains("php") || s.contains("php-fpm") }),
            ("Bun", { s, _ in s.contains("bun") }),
            ("Deno", { s, _ in s.contains("deno") }),
            ("Node", { s, _ in s.contains("node") }),
            ("Python", { s, _ in s.contains { $0.hasPrefix("python") } }),
            ("Ruby", { s, _ in s.contains("ruby") }),
            ("Java", { s, _ in s.contains("java") }),
        ]
        return rules.first { $0.1(set, joined) }?.0
    }
}

/// Lee los puertos abiertos con las llamadas del núcleo (libproc), sin lanzar `lsof`: unos
/// milisegundos y solo cuando se pide.
public enum PortScanner {
    public static func scan(excluding excluded: Set<Int32> = []) -> [ListeningPort] {
        let uid = getuid()
        var table: [Int32: (ppid: Int32, name: String)] = [:]
        var found: [(pid: Int32, port: Int, local: Bool, start: Date)] = []

        for pid in allPids() where pid > 0 && !excluded.contains(pid) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            table[pid] = (Int32(info.pbi_ppid), processName(pid, info))
            let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
            for (port, local) in listeningSockets(pid) {
                found.append((pid, port, local, start))
            }
        }

        // Un mismo proceso suele escuchar el mismo puerto en IPv4 e IPv6: una sola entrada.
        var merged: [String: ListeningPort] = [:]
        for item in found {
            let key = "\(item.pid):\(item.port)"
            if var existing = merged[key] {
                existing.localOnly = existing.localOnly && item.local
                merged[key] = existing
                continue
            }
            let name = table[item.pid]?.name ?? "?"
            var parents: [ProcessNode] = []
            var current = table[item.pid]?.ppid ?? 0
            while current > 1, parents.count < 12 {
                parents.append(ProcessNode(pid: current, name: table[current]?.name ?? "?", arguments: arguments(current)))
                guard let next = table[current]?.ppid else { break }
                current = next
            }
            merged[key] = ListeningPort(
                port: item.port, pid: item.pid, name: name, arguments: arguments(item.pid),
                executable: executablePath(item.pid), directory: workingDirectory(item.pid),
                started: item.start, localOnly: item.local, parents: parents)
        }
        return merged.values.sorted { ($0.isApp ? 1 : 0, $0.port) < ($1.isApp ? 1 : 0, $1.port) }
    }

    /// Hijos, nietos… de un proceso, para cerrar el servidor entero.
    public static func descendants(of root: Int32) -> [Int32] {
        let children = childrenTable()
        var result: [Int32] = []
        var queue = children[root] ?? []
        while let next = queue.popLast() {
            result.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    /// Hijos de cada proceso tuyo (pid del padre → pids).
    public static func childrenTable() -> [Int32: [Int32]] {
        let uid = getuid()
        var children: [Int32: [Int32]] = [:]
        for pid in allPids() where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            children[Int32(info.pbi_ppid), default: []].append(pid)
        }
        return children
    }

    /// Alguien acepta conexiones en ese puerto de este Mac (aunque sea de otro usuario).
    public static func isListening(port: Int) -> Bool {
        guard let p = UInt16(exactly: port) else { return false }
        let v4 = socket(AF_INET, SOCK_STREAM, 0)
        if v4 >= 0 {
            defer { close(v4) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = p.bigEndian
            addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(v4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok == 0 { return true }
        }
        let v6 = socket(AF_INET6, SOCK_STREAM, 0)
        if v6 >= 0 {
            defer { close(v6) }
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = p.bigEndian
            addr.sin6_addr = in6addr_loopback
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(v6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            if ok == 0 { return true }
        }
        return false
    }

    public static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    // MARK: libproc

    static func allPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func listeningSockets(_ pid: Int32) -> [(Int, Bool)] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }

        var result: [(Int, Bool)] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            guard port > 0 else { continue }
            result.append((port, isLoopback(tcp.tcpsi_ini)))
        }
        return result
    }

    private static func isLoopback(_ ini: in_sockinfo) -> Bool {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            let addr = UInt32(bigEndian: ini.insi_laddr.ina_46.i46a_addr4.s_addr)
            return addr >> 24 == 127
        }
        var v6 = ini.insi_laddr.ina_6
        return withUnsafeBytes(of: &v6) { raw in
            raw.prefix(15).allSatisfy { $0 == 0 } && raw[15] == 1
        }
    }

    private static func processName(_ pid: Int32, _ info: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return text(buffer) }
        var name = info.pbi_comm
        return withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return text(buffer)
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        var path = info.pvi_cdir.vip_path
        let text = withUnsafeBytes(of: &path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return text.isEmpty || text == "/" ? nil : text
    }

    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// Formato de KERN_PROCARGS2: argc (4 bytes), ruta del ejecutable, ceros de relleno y argv.
    static func parseArguments(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
