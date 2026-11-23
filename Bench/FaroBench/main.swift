import AppKit
import SwiftTerm

// Uso: FaroBench <ventanas> <metal 0|1> [comando]
let args = CommandLine.arguments
let count = args.count > 1 ? Int(args[1]) ?? 1 : 1
let metal = args.count > 2 && args[2] == "1"
let command = args.count > 3 ? args[3] : "sleep 100000"
let tabs = ProcessInfo.processInfo.environment["TABS"] == "1"
let scrollback = Int(ProcessInfo.processInfo.environment["SCROLLBACK"] ?? "")

final class Delegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var windows: [NSWindow] = []
    var views: [LocalProcessTerminalView] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        if tabs {
            let w = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 900, height: 560),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            w.level = .floating
            w.orderFrontRegardless()
            windows.append(w)
            for i in 0..<count {
                let t = LocalProcessTerminalView(frame: w.contentLayoutRect)
                t.autoresizingMask = [.width, .height]
                if metal { try? t.setUseMetal(true) }
                if let scrollback { t.changeScrollback(scrollback) }
                t.processDelegate = self
                if i == 0 { w.contentView = t }
                views.append(t)
                t.startProcess(executable: "/bin/zsh", args: ["-c", i == 0 ? command : "sleep 100000"])
            }
            print("ready"); return
        }
        for i in 0..<count {
            let w = NSWindow(contentRect: NSRect(x: 40 + i * 30, y: 80 + i * 20, width: 900, height: 560),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            let t = LocalProcessTerminalView(frame: w.contentLayoutRect)
            t.autoresizingMask = [.width, .height]
            if metal { try? t.setUseMetal(true) }
            t.processDelegate = self
            w.contentView = t
            w.level = .floating
            w.orderFrontRegardless()
            windows.append(w)
            t.startProcess(executable: "/bin/zsh", args: ["-c", i == 0 ? command : "sleep 100000"])
        }
        print("ready")
    }
    var relief: DispatchSourceSignal?
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        FileHandle.standardError.write("done \(Date().timeIntervalSince1970)\n".data(using: .utf8)!)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let d = Delegate()
    signal(SIGUSR1, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    src.setEventHandler { let freed = malloc_zone_pressure_relief(nil, 0); FileHandle.standardError.write("freed \(freed / 1_048_576) MB\n".data(using: .utf8)!) }
    src.resume()
    d.relief = src
    app.delegate = d
    app.setActivationPolicy(.accessory)
    app.run()
}
