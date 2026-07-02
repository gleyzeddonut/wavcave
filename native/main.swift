// WavCave — native standalone macOS app.
// A WKWebView window with the backend (Server.swift) running in-process, loading
// the UI from http://127.0.0.1:8765. No browser, no Python: own Dock icon, own ⌘Q.

import Cocoa
import WebKit

let PORT = Int(ProcessInfo.processInfo.environment["BF_PORT"] ?? "") ?? 8765
var serverToken = ""
func appURL() -> URL { URL(string: "http://127.0.0.1:\(PORT)/index.html?t=\(serverToken)")! }

// WKWebView that accepts folders dropped onto it and hands their real paths to the page.
final class DropWebView: WKWebView {
    private func folderURLs(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return [] }
        return objs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
    private func setDrag(_ on: Bool) { evaluateJavaScript("window.bfDragState&&window.bfDragState(\(on))", completionHandler: nil) }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        if folderURLs(info).isEmpty { return super.draggingEntered(info) }
        setDrag(true); return .copy
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        if folderURLs(info).isEmpty { return super.draggingUpdated(info) }
        return .copy
    }
    override func draggingExited(_ info: NSDraggingInfo?) { setDrag(false); super.draggingExited(info) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let urls = folderURLs(info)
        if urls.isEmpty { return super.performDragOperation(info) }
        setDrag(false)
        let paths = urls.map { $0.path }
        if let data = try? JSONSerialization.data(withJSONObject: paths),
           let json = String(data: data, encoding: .utf8) {
            evaluateJavaScript("window.bfAddFolders&&window.bfAddFolders(\(json))", completionHandler: nil)
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var server: WavCaveServer?
    let updateRepo = "gleyzeddonut/wavcave"
    var latestTag = ""
    var latestAssetURL = ""
    var stagedApp: String?
    var didCheckUpdate = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        ensureBackendThenLoad()
        // Long-running instances should still learn about new releases.
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    // If WebKit recycles the page's content process (e.g. under memory pressure),
    // the page goes blank and its JS->native bridge dies silently — reload so the
    // app heals itself instead of looking alive but ignoring every click.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("WavCave: web content process terminated — reloading UI")
        webView.load(URLRequest(url: appURL()))
    }

    // MARK: window + webview
    func buildWindow() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()   // persistent localStorage (favorites, ignores, settings)
        cfg.userContentController.add(self, name: "bf")   // messages from the page (update flow)

        let frame = NSRect(x: 0, y: 0, width: 1140, height: 820)
        webView = DropWebView(frame: frame, configuration: cfg)
        webView.registerForDraggedTypes([.fileURL])         // accept folder drops
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")  // avoid white flash

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "WavCave"
        window.setFrameAutosaveName("WavCaveMainWindow")
        window.minSize = NSSize(width: 720, height: 480)
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: backend (in-process — see Server.swift)
    func dataDir() -> String { NSString(string: "~/Library/Application Support/WavCave").expandingTildeInPath }

    func ensureBackendThenLoad() {
        // One-time migration from the old "Bounce Finder" brand: carry the existing
        // library, settings, scan cache and waveform peaks over so nothing is lost.
        let fm = FileManager.default
        let old = NSString(string: "~/Library/Application Support/BounceFinder").expandingTildeInPath
        if !fm.fileExists(atPath: dataDir()), fm.fileExists(atPath: old) {
            try? fm.moveItem(atPath: old, toPath: dataDir())
        }

        serverToken = Self.randomToken()
        let s = WavCaveServer(port: UInt16(PORT), rootDir: Bundle.main.resourcePath ?? ".",
                              dataDir: dataDir(), token: serverToken)
        s.pickFolder = { [weak self] in self?.pickFolderPanel() }
        do {
            try s.start()
            server = s
        } catch {
            // Port taken — most likely another WavCave instance owns the server.
            // Reuse its token (written to the data dir on start) so this window still works.
            NSLog("WavCave: backend not started (\(error)); reusing running server")
            if let t = try? String(contentsOfFile: dataDir() + "/token", encoding: .utf8) {
                serverToken = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        webView.load(URLRequest(url: appURL()))
    }

    static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // Native folder picker for /api/pick; called from a server worker thread.
    func pickFolderPanel() -> String? {
        var result: String?
        let work = {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Choose a folder to search for bounce files"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK { result = panel.url?.path }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    // MARK: lifecycle
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { server?.stop() }

    // Re-show the window if the Dock icon is clicked while running.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: in-app updates (downloads straight from the public GitHub release — no gh, no auth)
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        if !didCheckUpdate { didCheckUpdate = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkForUpdate() }
        }
    }
    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "check":    checkForUpdate(manual: true)
        case "download": downloadUpdate()
        case "restart":  applyUpdateAndRestart()
        default: break
        }
    }
    @objc func checkForUpdatesMenu() { checkForUpdate(manual: true) }
    @objc func openSettingsMenu() { web("window.bfOpenSettings && window.bfOpenSettings()") }

    // Fetch bytes from a URL synchronously (used for the GitHub API + asset download).
    func httpData(_ url: URL, timeout: TimeInterval = 12) -> (code: Int, data: Data?) {
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue("WavCave", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var code = 0; var out: Data?
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let h = resp as? HTTPURLResponse { code = h.statusCode }
            out = d; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return (code, out)
    }
    // Download a file (follows redirects to GitHub's asset CDN) to a local path.
    func httpDownload(_ url: URL, toPath path: String) -> Bool {
        var req = URLRequest(url: url); req.timeoutInterval = 300
        req.setValue("WavCave", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.downloadTask(with: req) { tmp, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200, let tmp = tmp {
                let fm = FileManager.default
                try? fm.removeItem(atPath: path)
                do { try fm.moveItem(at: tmp, to: URL(fileURLWithPath: path)); ok = true } catch {}
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 320)
        return ok
    }
    func currentVersion() -> String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    func verParts(_ s: String) -> [Int] {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return t.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
    }
    func isNewer(_ tag: String, than cur: String) -> Bool {
        let a = verParts(tag), b = verParts(cur)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    func jsStr(_ s: String) -> String {   // safe JS string literal
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }
    func web(_ js: String) { DispatchQueue.main.async { self.webView.evaluateJavaScript(js, completionHandler: nil) } }
    func updateDir() -> String { NSString(string: "~/Library/Application Support/WavCave/update").expandingTildeInPath }

    func checkForUpdate(manual: Bool = false) {
        DispatchQueue.global().async {
            let url = URL(string: "https://api.github.com/repos/\(self.updateRepo)/releases/latest")!
            let r = self.httpData(url)
            guard r.code == 200, let d = r.data,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tag = j["tag_name"] as? String, !tag.isEmpty else {
                if manual { self.web("window.bfUpdateNone&&window.bfUpdateNone(false)") }
                return
            }
            let notes = (j["body"] as? String) ?? ""
            if let assets = j["assets"] as? [[String: Any]],
               let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
               let u = zip["browser_download_url"] as? String {
                self.latestAssetURL = u
            } else {
                self.latestAssetURL = ""
            }
            if self.isNewer(tag, than: self.currentVersion()) {
                self.latestTag = tag
                self.web("window.bfUpdate&&window.bfUpdate(\(self.jsStr(tag)),\(self.jsStr(notes)))")
            } else if manual {
                self.web("window.bfUpdateNone&&window.bfUpdateNone(true)")
            }
        }
    }
    func downloadUpdate() {
        let tag = latestTag
        guard !tag.isEmpty else {
            NSLog("WavCave: download requested but no known update tag — telling UI to re-check")
            web("window.bfUpdateError&&window.bfUpdateError()")
            return
        }
        NSLog("WavCave: downloading update \(tag)")
        DispatchQueue.global().async {
            let fm = FileManager.default, dir = self.updateDir()
            try? fm.removeItem(atPath: dir)
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Prefer the asset URL from the API; fall back to the conventional public download path.
            var assetStr = self.latestAssetURL
            if assetStr.isEmpty {
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                assetStr = "https://github.com/\(self.updateRepo)/releases/download/\(tag)/WavCave-\(v).zip"
            }
            let zipPath = dir + "/update.zip"
            guard let assetURL = URL(string: assetStr), self.httpDownload(assetURL, toPath: zipPath) else {
                self.web("window.bfUpdateError&&window.bfUpdateError()"); return
            }
            let unpack = dir + "/unpacked"
            try? fm.removeItem(atPath: unpack); try? fm.createDirectory(atPath: unpack, withIntermediateDirectories: true)
            let dt = Process(); dt.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); dt.arguments = ["-x", "-k", zipPath, unpack]
            do { try dt.run(); dt.waitUntilExit() } catch {}
            guard let appName = (try? fm.contentsOfDirectory(atPath: unpack))?.first(where: { $0.hasSuffix(".app") }) else {
                self.web("window.bfUpdateError&&window.bfUpdateError()"); return
            }
            self.stagedApp = unpack + "/" + appName
            self.web("window.bfUpdateReady&&window.bfUpdateReady()")
        }
    }
    func applyUpdateAndRestart() {
        guard let staged = stagedApp else {
            NSLog("WavCave: restart requested but no staged update")
            web("window.bfUpdateError&&window.bfUpdateError()")
            return
        }
        NSLog("WavCave: applying staged update from \(staged)")
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let sp = NSString(string: "~/Library/Application Support/WavCave/swap.sh").expandingTildeInPath
        // Stage the new copy NEXT TO the destination, then swap with renames — the old
        // app is only removed after the new one is fully in place, so a failed copy
        // can never leave the user with no app at all.
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        sleep 0.5
        DEST="\(dest)"
        STAGE="$DEST.update-new"
        OLD="$DEST.update-old"
        /bin/rm -rf "$STAGE" "$OLD"
        if /usr/bin/ditto "\(staged)" "$STAGE"; then
          /bin/mv "$DEST" "$OLD" 2>/dev/null
          if /bin/mv "$STAGE" "$DEST"; then
            /bin/rm -rf "$OLD" "\(updateDir())"
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
          else
            /bin/mv "$OLD" "$DEST" 2>/dev/null
            /bin/rm -rf "$STAGE"
          fi
        else
          /bin/rm -rf "$STAGE"
        fi
        /usr/bin/open "$DEST"
        """
        try? script.write(toFile: sp, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh '\(sp)' >/tmp/bouncefinder_update.log 2>&1 &"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: minimal main menu (gives ⌘Q + text-field editing shortcuts)
    func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About WavCave", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(.separator())
        let upd = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        upd.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WavCave", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WavCave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let winItem = NSMenuItem(); mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window"); winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
