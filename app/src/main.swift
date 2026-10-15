import AppKit
import Foundation

// ---------------------------------------------------------------------------
// Samsung SpliX Installer - GUI front-end for the privileged shell scripts
// bundled in Resources/scripts.  Those scripts do all the real work; this app
// only detects printers, asks for admin rights and shows the result.
//
// Localisation: English (default) + Portuguese, via en.lproj / pt.lproj.
// ---------------------------------------------------------------------------

let kInstallLog = "/var/log/splixinstaller.log"

func L(_ key: String) -> String { return NSLocalizedString(key, comment: "") }

func appName() -> String {
    return (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "Samsung SpliX Installer"
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var titleLabel: NSTextField!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var installButton: NSButton!
    var uninstallButton: NSButton!
    var refreshButton: NSButton!
    var spinner: NSProgressIndicator!

    var payloadDir = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        payloadDir = preparePayload()
        buildMenu()
        buildWindow()
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Payload

    /// Copy the bundled payload to a temp dir without spaces so the privileged
    /// shell script can be invoked without hairy quoting.
    func preparePayload() -> String {
        let fm = FileManager.default
        let dst = (NSTemporaryDirectory() as NSString).appendingPathComponent("splixinstaller-\(getpid())")
        try? fm.removeItem(atPath: dst)
        try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)

        if let res = Bundle.main.resourcePath {
            for item in ["bin", "ppd", "backend", "scripts"] {
                let src = (res as NSString).appendingPathComponent(item)
                if fm.fileExists(atPath: src) {
                    try? fm.copyItem(atPath: src, toPath: (dst as NSString).appendingPathComponent(item))
                }
            }
        }
        return dst
    }

    // MARK: - UI

    func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(format: L("menu.about"), appName()),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L("menu.quit"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 660, height: 540)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = appName()
        window.center()

        let content = NSView(frame: rect)

        titleLabel = NSTextField(labelWithString: L("ui.headline"))
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.frame = NSRect(x: 20, y: 496, width: 620, height: 22)
        content.addSubview(titleLabel)

        let sub = NSTextField(wrappingLabelWithString: L("ui.subtitle"))
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 20, y: 448, width: 620, height: 44)
        content.addSubview(sub)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.frame = NSRect(x: 20, y: 420, width: 620, height: 20)
        content.addSubview(statusLabel)

        installButton = NSButton(title: L("ui.install"), target: self, action: #selector(doInstall))
        installButton.frame = NSRect(x: 20, y: 376, width: 150, height: 32)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        content.addSubview(installButton)

        uninstallButton = NSButton(title: L("ui.uninstall"), target: self, action: #selector(doUninstall))
        uninstallButton.frame = NSRect(x: 180, y: 376, width: 130, height: 32)
        uninstallButton.bezelStyle = .rounded
        content.addSubview(uninstallButton)

        refreshButton = NSButton(title: L("ui.check"), target: self, action: #selector(doRefresh))
        refreshButton.frame = NSRect(x: 320, y: 376, width: 110, height: 32)
        refreshButton.bezelStyle = .rounded
        content.addSubview(refreshButton)

        spinner = NSProgressIndicator(frame: NSRect(x: 442, y: 382, width: 20, height: 20))
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 620, height: 340))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.isVerticallyResizable = true
        scroll.documentView = logView
        content.addSubview(scroll)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    func appendLog(_ text: String) {
        DispatchQueue.main.async {
            self.logView.string += text
            if !text.hasSuffix("\n") { self.logView.string += "\n" }
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    @discardableResult
    func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func appleQuote(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a command as root via the standard administrator prompt.
    func runPrivileged(_ args: [String], completion: @escaping (Bool) -> Void) {
        let cmd = args.map { shellQuote($0) }.joined(separator: " ")
        let script = "do shell script \"\(appleQuote(cmd))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            completion(false)
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 { appendLog(out) }
        completion(p.terminationStatus == 0)
    }

    func readLog() -> String {
        if let t = try? String(contentsOfFile: kInstallLog, encoding: .utf8) {
            let lines = t.split(separator: "\n")
            return lines.suffix(60).joined(separator: "\n")
        }
        return L("log.nolog")
    }

    // MARK: - Actions

    @objc func doRefresh() { refresh() }

    func refresh() {
        let installed = FileManager.default.fileExists(atPath: "/Library/Printers/Splix/splixusb")
        let (_, out) = run("/bin/bash", [payloadDir + "/scripts/install.sh", "--detect", payloadDir])

        var found: [String] = []
        var unsupported: [String] = []
        for line in out.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if f.count >= 6 && f[0] == "FOUND" {
                found.append(String(format: L("ui.found.line"), f[2], f[3], f[5], f[4]))
            } else if f.count >= 4 && f[0] == "UNSUPPORTED" {
                unsupported.append(String(format: L("ui.unsupported.line"), f[2], f[3]))
            }
        }

        statusLabel.stringValue = installed ? L("ui.state.installed") : L("ui.state.notinstalled")

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        appendLog("\n" + String(format: L("log.check"), df.string(from: Date())))
        if found.isEmpty && unsupported.isEmpty {
            appendLog(L("ui.none"))
        } else {
            if !found.isEmpty {
                appendLog(L("ui.found"))
                appendLog(found.joined(separator: "\n"))
            }
            if !unsupported.isEmpty {
                appendLog(L("ui.unsupported"))
                appendLog(unsupported.joined(separator: "\n"))
            }
        }
    }

    @objc func doInstall() {
        setBusy(true, L("log.busy.install"))
        appendLog("\n" + L("log.install"))
        DispatchQueue.global().async {
            self.runPrivileged(["/bin/bash", self.payloadDir + "/scripts/install.sh", self.payloadDir]) { ok in
                self.appendLog(self.readLog())
                self.appendLog(ok ? L("log.install.ok") : L("log.install.fail"))
                self.setBusy(false, nil)
                self.refresh()
            }
        }
    }

    @objc func doUninstall() {
        setBusy(true, L("log.busy.uninstall"))
        appendLog("\n" + L("log.uninstall"))
        DispatchQueue.global().async {
            self.runPrivileged(["/bin/bash", self.payloadDir + "/scripts/uninstall.sh"]) { ok in
                self.appendLog(ok ? L("log.uninstall.ok") : L("log.uninstall.fail"))
                self.setBusy(false, nil)
                self.refresh()
            }
        }
    }

    func setBusy(_ busy: Bool, _ message: String?) {
        DispatchQueue.main.async {
            if busy { self.spinner.startAnimation(nil) } else { self.spinner.stopAnimation(nil) }
            self.installButton.isEnabled = !busy
            self.uninstallButton.isEnabled = !busy
            self.refreshButton.isEnabled = !busy
            if let m = message { self.statusLabel.stringValue = m }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
