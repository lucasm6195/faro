import Foundation

/// Reconoce en la salida de un comando que el puerto que quería ya estaba ocupado.
public enum PortConflict {
    /// Mensajes con el número de puerto. El grupo 1 es el puerto.
    static let patterns: [String] = [
        // Node: «Error: listen EADDRINUSE: address already in use :::3000»
        #"EADDRINUSE[^\n]*:(\d{2,5})\b"#,
        // Next.js, Vite, Astro, Nuxt, Flask…: «Port 3000 is in use», «Port 5173 is already in use»
        #"[Pp]ort (\d{2,5}) (?:is )?(?:already )?(?:in use|being used|is taken|unavailable)"#,
        // Expo / Metro: «Port 8081 is being used by another process»
        #"[Pp]ort (\d{2,5}) is being used"#,
        // Rails / Puma: «Address already in use - bind(2) for "127.0.0.1" port 3000»
        #"[Aa]ddress already in use[^\n]*?port (\d{2,5})"#,
        // Go: «listen tcp :8080: bind: address already in use»
        #"listen tcp[^\n]*?:(\d{2,5}): bind: address already in use"#,
        // Docker: «Bind for 0.0.0.0:5432 failed: port is already allocated»
        #"Bind for [^\s]*?:(\d{2,5}) failed: port is already allocated"#,
        // Genérico: «:3000 already in use», «3000 already in use»
        #"[:\s](\d{2,5}) (?:is )?already in use"#,
    ]

    /// Mensajes sin número: el puerto se saca del comando.
    static let portless: [String] = [
        "address already in use", "eaddrinuse", "that port is already in use", "errno 48", "errno 98",
        "port is already allocated", "address in use",
    ]

    /// El puerto ocupado, si la salida dice que no se pudo usar.
    public static func port(in output: String, command: String? = nil) -> Int? {
        let range = NSRange(output.startIndex..., in: output)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: output, range: range).last,
                  let r = Range(match.range(at: 1), in: output),
                  let port = Int(output[r]), (1...65_535).contains(port) else { continue }
            return port
        }
        let lower = output.lowercased()
        if portless.contains(where: lower.contains), let command {
            return self.port(inCommand: command)
        }
        return nil
    }

    /// `npm run dev -- --port 4000`, `PORT=4000 node app`, `python3 -m http.server 8000`,
    /// `rails s -p 3001`, `vite --port=5174`.
    public static func port(inCommand command: String) -> Int? {
        let patterns = [
            #"(?:^|\s)PORT=(\d{2,5})\b"#,
            #"--port[= ](\d{2,5})\b"#,
            #"(?:^|\s)-p\s?(\d{2,5})\b"#,
            #"http\.server\s+(\d{2,5})\b"#,
            #"runserver\s+(?:[\w.]+:)?(\d{2,5})\b"#,
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})\b"#,
        ]
        let range = NSRange(command.startIndex..., in: command)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: command, range: range),
                  let r = Range(match.range(at: 1), in: command),
                  let port = Int(command[r]) else { continue }
            return port
        }
        // Sin puerto explícito: los habituales de cada herramienta.
        let words = Set(command.lowercased().split(whereSeparator: { " /=".contains($0) }).map(String.init))
        if words.contains("http.server") { return 8000 }
        if words.contains("runserver") { return 8000 }
        if words.contains("flask") { return 5000 }
        if words.contains("rails") || words.contains("puma") { return 3000 }
        return nil
    }
}
