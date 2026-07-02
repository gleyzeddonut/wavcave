// WavCave backend, in Swift — a direct port of the old server.py so the app no
// longer needs a system Python (whose absence pops the Command Line Tools dialog).
// Scans for bounce audio, streams it with Range support, computes waveform peaks
// via afconvert, persists user state, and reveals files in Finder.
//
// Security: every request must carry a loopback Host header, and when a token is
// configured every /api call must echo it back (?t=…), so neither another local
// process nor a DNS-rebound web page can drive the API.

import Foundation
import CryptoKit
import Darwin

private let AUDIO_EXT: Set<String> = ["wav", "mp3"]

// MARK: - keyword matching (what counts as a "bounce" folder)

struct FolderKeyword {
    let word: String
    let caseSensitive: Bool
    let pluralize: Bool
}

private let DEFAULT_KEYWORDS = [FolderKeyword(word: "bounce", caseSensitive: false, pluralize: true)]

func kwPlural(_ w: String) -> String {
    let lw = w.lowercased()
    if lw.hasSuffix("s") || lw.hasSuffix("x") || lw.hasSuffix("z") || lw.hasSuffix("ch") || lw.hasSuffix("sh") { return w + "es" }
    if w.count > 1 && lw.hasSuffix("y") {
        let before = lw[lw.index(lw.endIndex, offsetBy: -2)]
        if !"aeiou".contains(before) { return String(w.dropLast()) + "ies" }
    }
    return w + "s"
}

/// Build a folder-name matcher from a keyword config list (mirrors the web UI's rules).
func segMatcher(_ kws: [FolderKeyword]?) -> (String) -> Bool {
    var cs = Set<String>(), ci = Set<String>()
    for kw in (kws?.isEmpty == false ? kws! : DEFAULT_KEYWORDS) {
        let w = kw.word.trimmingCharacters(in: .whitespaces)
        if w.isEmpty { continue }
        var cands = [w]
        if kw.pluralize {
            let p = kwPlural(w)
            if p != w { cands.append(p) }
        }
        for c in cands {
            if kw.caseSensitive { cs.insert(c) } else { ci.insert(c.lowercased()) }
        }
    }
    if cs.isEmpty && ci.isEmpty {
        for kw in DEFAULT_KEYWORDS {
            ci.insert(kw.word.lowercased())
            ci.insert(kwPlural(kw.word).lowercased())
        }
    }
    return { seg in cs.contains(seg) || ci.contains(seg.lowercased()) }
}

func parseKeywords(_ raw: String?) -> [FolderKeyword]? {
    guard let raw = raw, !raw.isEmpty,
          let data = raw.data(using: .utf8),
          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    return arr.map { d in
        FolderKeyword(word: (d["word"] as? String) ?? "",
                      caseSensitive: (d["caseSensitive"] as? Bool) ?? false,
                      pluralize: (d["pluralize"] as? Bool) ?? false)
    }
}

// MARK: - small helpers

func sha1Hex(_ s: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Resolve symlinks like Python's os.path.realpath (which tolerates missing paths).
func realPathOf(_ p: String) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    if let r = realpath(p, &buf) { return String(cString: r) }
    var u = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    if u.count > 1 && u.hasSuffix("/") { u = String(u.dropLast()) }
    return u
}

struct StatInfo {
    let size: Int64
    let mtime: Double
    let blocks: Int64
    let isFile: Bool
}

func statPath(_ p: String) -> StatInfo? {
    var st = stat()
    guard stat(p, &st) == 0 else { return nil }
    let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    return StatInfo(size: Int64(st.st_size), mtime: mtime, blocks: Int64(st.st_blocks), isFile: (st.st_mode & S_IFMT) == S_IFREG)
}

/// True if the file's bytes aren't on disk yet (e.g. a Dropbox online-only placeholder).
func isOnlineOnly(_ st: StatInfo) -> Bool {
    return st.size > 0 && st.blocks * 512 < st.size
}

func mimeType(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js": return "text/javascript"
    case "css": return "text/css"
    case "json": return "application/json"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "svg": return "image/svg+xml"
    case "ico": return "image/x-icon"
    case "wav": return "audio/x-wav"
    case "mp3": return "audio/mpeg"
    case "txt": return "text/plain; charset=utf-8"
    default: return "application/octet-stream"
    }
}

// MARK: - HTTP request

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // keys lowercased
    let body: Data
}

// MARK: - server

final class WavCaveServer {
    let port: UInt16
    let rootDir: String     // static files (index.html) live here
    let dataDir: String     // scan cache, peaks cache, state.json, token file
    let token: String       // "" disables token checks (dev / tests opting out)

    /// Set by the app to show a native folder picker (NSOpenPanel). Called off the main thread.
    var pickFolder: (() -> String?)?

    private var allowed = Set<String>()          // folders we may read/reveal
    private let allowedLock = NSLock()
    private var listenFD: Int32 = -1

    // Prefetch (cloud-file download) worker pool. Materializing Dropbox/iCloud
    // placeholders is expensive kernel-level work: an unbounded fan-out can wedge
    // FileProvider for the WHOLE machine (every app's file I/O stalls until reboot).
    // So: a fixed pool of 3 workers drains an explicit queue, nothing else ever
    // reads a dataless file implicitly.
    private var pfQueue = [String]()
    private var pfInFlight = Set<String>()
    private let pfCond = NSCondition()
    // afconvert decodes are CPU/IO heavy; never run more than 2 at once.
    private let peaksGate = DispatchSemaphore(value: 2)

    private var scansDir: String { dataDir + "/scans" }
    private var peaksDir: String { dataDir + "/peaks" }
    private var stateFile: String { dataDir + "/state.json" }

    init(port: UInt16, rootDir: String, dataDir: String, token: String) {
        self.port = port
        self.rootDir = realPathOf(rootDir)
        self.dataDir = dataDir
        self.token = token
    }

    enum ServerError: Error { case socket(String) }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.socket("bind failed (port \(port) in use?)")
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw ServerError.socket("listen failed")
        }
        listenFD = fd
        writeTokenFile()
        for _ in 0..<3 { Thread.detachNewThread { [weak self] in self?.prefetchWorker() } }
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    /// Long-lived worker: pulls one queued path at a time and reads it end-to-end,
    /// which forces the cloud provider to download it. Bounded by the pool size.
    private func prefetchWorker() {
        while true {
            pfCond.lock()
            while pfQueue.isEmpty { pfCond.wait() }
            let path = pfQueue.removeFirst()
            pfCond.unlock()
            if let fh = FileHandle(forReadingAtPath: path) {
                while let d = try? fh.read(upToCount: 1 << 20), !d.isEmpty {}
                try? fh.close()
            }
            pfCond.lock(); pfInFlight.remove(path); pfCond.unlock()
        }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    /// Persist the current token (0600) so a second app instance can reuse the running server.
    private func writeTokenFile() {
        guard !token.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let p = dataDir + "/token"
        try? token.write(toFile: p, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let conn = accept(listenFD, &addr, &len)
            if conn < 0 {
                if listenFD < 0 { break }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(conn)
            }
        }
    }

    // MARK: connection / request parsing

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let req = readRequest(fd) else { return }
        route(req, fd)
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd = -1
        while buf.count < 65536 {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            if let r = buf.range(of: sep) { headerEnd = r.lowerBound; break }
        }
        guard headerEnd >= 0 else { return nil }
        guard let head = String(data: buf.subdata(in: 0..<headerEnd), encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let reqLine = lines.removeFirst().components(separatedBy: " ")
        guard reqLine.count >= 2 else { return nil }
        let method = reqLine[0]
        let target = reqLine[1]

        var headers = [String: String]()
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        // body (POST)
        var body = buf.subdata(in: (headerEnd + 4)..<buf.count)
        if let cl = headers["content-length"], let want = Int(cl), want > 0 {
            guard want <= 16 * 1024 * 1024 else { return nil }
            while body.count < want {
                let n = recv(fd, &chunk, min(chunk.count, want - body.count), 0)
                if n <= 0 { break }
                body.append(contentsOf: chunk[0..<n])
            }
        } else {
            body = Data()
        }

        // split path / query
        var path = target, queryStr = ""
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            queryStr = String(target[target.index(after: q)...])
        }
        var query = [String: String]()
        for pair in queryStr.components(separatedBy: "&") where !pair.isEmpty {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let k = kv[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[0]
            let v = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
            if query[k] == nil { query[k] = v }
        }
        return HTTPRequest(method: method, path: path.removingPercentEncoding ?? path, query: query, headers: headers, body: body)
    }

    // MARK: response helpers

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { ok = data.isEmpty; return }
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, base.advanced(by: off), raw.count - off, 0)
                if n <= 0 { ok = false; return }
                off += n
            }
        }
        return ok
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    private func sendHead(_ fd: Int32, code: Int, headers: [(String, String)]) {
        var out = "HTTP/1.1 \(code) \(statusText(code))\r\n"
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "Connection: close\r\n\r\n"
        writeAll(fd, Data(out.utf8))
    }

    private func send(_ fd: Int32, code: Int, contentType: String, body: Data, extra: [(String, String)] = []) {
        var headers: [(String, String)] = [("Content-Type", contentType), ("Content-Length", String(body.count))]
        headers.append(contentsOf: extra)
        sendHead(fd, code: code, headers: headers)
        if !body.isEmpty { writeAll(fd, body) }
    }

    private func sendJSON(_ fd: Int32, _ obj: Any, code: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        send(fd, code: code, contentType: "application/json", body: data)
    }

    // MARK: security

    private func hostAllowed(_ req: HTTPRequest) -> Bool {
        guard let host = req.headers["host"]?.lowercased() else { return false }
        let bare = host.hasSuffix(":\(port)") ? String(host.dropLast(":\(port)".count)) : host
        return bare == "127.0.0.1" || bare == "localhost" || bare == "[::1]"
    }

    private func tokenOK(_ req: HTTPRequest) -> Bool {
        if token.isEmpty { return true }
        return req.query["t"] == token
    }

    private func isAllowedPath(_ p: String) -> Bool {
        let rp = realPathOf(p)
        allowedLock.lock(); defer { allowedLock.unlock() }
        for r in allowed where rp == r || rp.hasPrefix(r + "/") { return true }
        return false
    }

    private func allowPath(_ p: String) {
        let rp = realPathOf(p)
        allowedLock.lock(); allowed.insert(rp); allowedLock.unlock()
    }

    // MARK: routing

    private func route(_ req: HTTPRequest, _ fd: Int32) {
        guard hostAllowed(req) else {
            send(fd, code: 403, contentType: "text/plain", body: Data("forbidden host".utf8))
            return
        }
        if req.path.hasPrefix("/api/") && !tokenOK(req) {
            sendJSON(fd, ["error": "unauthorized"], code: 401)
            return
        }
        if req.method == "POST" {
            if req.path == "/api/state" { return postState(req, fd) }
            return send(fd, code: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
        guard req.method == "GET" || req.method == "HEAD" else {
            return send(fd, code: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
        switch req.path {
        case "/api/ping":       sendJSON(fd, ["ok": true])
        case "/api/pick":       apiPick(fd)
        case "/api/scan":       apiScan(req, fd)
        case "/api/scan_stream": apiScanStream(req, fd)
        case "/api/cached":     apiCached(req, fd)
        case "/api/peaks":      apiPeaks(req, fd)
        case "/api/state":      apiState(fd)
        case "/api/reveal":     apiReveal(req, fd)
        case "/api/prefetch":   apiPrefetch(req, fd)
        case "/api/status":     apiStatus(req, fd)
        case "/api/file":       apiFile(req, fd)
        default:                serveStatic(req, fd)
        }
    }

    // MARK: endpoints

    private func apiPick(_ fd: Int32) {
        guard let picker = pickFolder, let path = picker() else {
            return sendJSON(fd, ["cancelled": true])
        }
        allowPath(path)
        sendJSON(fd, ["path": path])
    }

    private func apiScan(_ req: HTTPRequest, _ fd: Int32) {
        guard let root = req.query["path"], !root.isEmpty, isDir(root) else {
            return sendJSON(fd, ["error": "Folder not found"], code: 400)
        }
        allowPath(root)
        let items = scan(root: root, kws: parseKeywords(req.query["kw"]))
        writeCache(root: root, items: items)
        sendJSON(fd, ["root": root, "items": items])
    }

    private func apiScanStream(_ req: HTTPRequest, _ fd: Int32) {
        // NDJSON stream: one {"item":…} line per file as it's discovered,
        // then a final {"done":true,…}. Lets the UI tick the count per file.
        guard let root = req.query["path"], !root.isEmpty, isDir(root) else {
            return sendJSON(fd, ["error": "Folder not found"], code: 400)
        }
        allowPath(root)
        sendHead(fd, code: 200, headers: [("Content-Type", "application/x-ndjson"), ("Cache-Control", "no-store")])
        var items = [[String: Any]]()
        let kws = parseKeywords(req.query["kw"])
        scanIter(root: root, kws: kws) { item in
            items.append(item)
            guard let line = try? JSONSerialization.data(withJSONObject: ["item": item]) else { return true }
            return self.writeAll(fd, line + Data("\n".utf8))
        }
        writeCache(root: root, items: items)
        if let done = try? JSONSerialization.data(withJSONObject: ["done": true, "root": root, "count": items.count]) {
            writeAll(fd, done + Data("\n".utf8))
        }
    }

    private func apiCached(_ req: HTTPRequest, _ fd: Int32) {
        guard let root = req.query["path"], !root.isEmpty, isDir(root) else {
            return sendJSON(fd, ["miss": true])
        }
        allowPath(root)   // allow streaming cached files without a rescan
        guard let data = readCache(root: root), let items = data["items"] else {
            return sendJSON(fd, ["miss": true])
        }
        sendJSON(fd, ["root": root, "items": items, "cached": true])
    }

    private func apiPeaks(_ req: HTTPRequest, _ fd: Int32) {
        guard let t = req.query["path"], !t.isEmpty, isAllowedPath(t), let st = statPath(t), st.isFile else {
            return sendJSON(fd, ["peaks": [], "error": "forbidden"], code: 403)
        }
        // Never force a cloud download just to draw a waveform: the client keeps
        // its placeholder and retries once the file is local (e.g. after playing it).
        if isOnlineOnly(st) {
            return sendJSON(fd, ["peaks": [], "online": true])
        }
        sendJSON(fd, ["peaks": getPeaks(t)])
    }

    private func apiState(_ fd: Int32) {
        if let data = FileManager.default.contents(atPath: stateFile),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            send(fd, code: 200, contentType: "application/json", body: data)
        } else {
            sendJSON(fd, [String: Any]())
        }
    }

    private func postState(_ req: HTTPRequest, _ fd: Int32) {
        guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return sendJSON(fd, ["error": "expected object"], code: 400)
        }
        do {
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            let tmp = stateFile + ".tmp"
            let data = try JSONSerialization.data(withJSONObject: obj)
            try data.write(to: URL(fileURLWithPath: tmp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: stateFile), withItemAt: URL(fileURLWithPath: tmp))
            sendJSON(fd, ["ok": true])
        } catch {
            sendJSON(fd, ["error": String(describing: error)], code: 400)
        }
    }

    private func apiReveal(_ req: HTTPRequest, _ fd: Int32) {
        guard let t = req.query["path"], !t.isEmpty, isAllowedPath(t), FileManager.default.fileExists(atPath: t) else {
            return sendJSON(fd, ["error": "forbidden"], code: 403)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-R", t]
        try? p.run()
        sendJSON(fd, ["ok": true])
    }

    private func apiPrefetch(_ req: HTTPRequest, _ fd: Int32) {
        guard let t = req.query["path"], !t.isEmpty, isAllowedPath(t), statPath(t)?.isFile == true else {
            return sendJSON(fd, ["error": "forbidden"], code: 403)
        }
        pfCond.lock()
        if !pfInFlight.contains(t) {
            pfInFlight.insert(t)
            pfQueue.append(t)
            pfCond.signal()
        }
        pfCond.unlock()
        sendJSON(fd, ["ok": true])
    }

    private func apiStatus(_ req: HTTPRequest, _ fd: Int32) {
        guard let t = req.query["path"], !t.isEmpty, isAllowedPath(t), let st = statPath(t), st.isFile else {
            return sendJSON(fd, ["error": "forbidden"], code: 403)
        }
        sendJSON(fd, ["online": isOnlineOnly(st)])
    }

    // MARK: static files

    private func serveStatic(_ req: HTTPRequest, _ fd: Int32) {
        var rel = req.path
        while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        if rel.isEmpty { rel = "index.html" }
        let segs = rel.components(separatedBy: "/")
        guard !segs.contains(".."), !segs.contains("") else {   // no traversal, no "//"
            return send(fd, code: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
        let fp = rootDir + "/" + rel
        guard statPath(fp)?.isFile == true, let data = FileManager.default.contents(atPath: fp) else {
            return send(fd, code: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }
        send(fd, code: 200, contentType: mimeType(fp), body: data)
    }

    // MARK: audio file streaming (Range support)

    private func apiFile(_ req: HTTPRequest, _ fd: Int32) {
        guard let path = req.query["path"], !path.isEmpty, isAllowedPath(path),
              let st = statPath(path), st.isFile,
              let fh = FileHandle(forReadingAtPath: path) else {
            return send(fd, code: 403, contentType: "text/plain", body: Data("forbidden".utf8))
        }
        defer { try? fh.close() }
        let size = st.size
        let ctype = mimeType(path)
        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let rng = req.headers["range"],
           let m = rng.range(of: #"bytes=(\d*)-(\d*)"#, options: .regularExpression) {
            let spec = String(rng[m]).dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let a = parts.count > 0 ? String(parts[0]) : ""
            let b = parts.count > 1 ? String(parts[1]) : ""
            if a.isEmpty && !b.isEmpty {
                // suffix range "bytes=-N": the last N bytes of the file
                start = max(0, size - (Int64(b) ?? 0))
                end = size - 1
            } else {
                start = Int64(a) ?? 0
                end = b.isEmpty ? size - 1 : (Int64(b) ?? (size - 1))
            }
            end = min(end, size - 1)
            start = min(start, max(end, 0))
            partial = true
        }
        if size == 0 { start = 0; end = -1 }
        let length = max(0, end - start + 1)
        var headers: [(String, String)] = [("Content-Type", ctype), ("Accept-Ranges", "bytes"), ("Content-Length", String(length))]
        if partial { headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)")) }
        sendHead(fd, code: partial ? 206 : 200, headers: headers)
        if req.method == "HEAD" { return }
        try? fh.seek(toOffset: UInt64(start))
        var remaining = length
        while remaining > 0 {
            let want = Int(min(65536, remaining))
            guard let chunk = try? fh.read(upToCount: want), !chunk.isEmpty else { break }
            if !writeAll(fd, chunk) { break }
            remaining -= Int64(chunk.count)
        }
    }

    // MARK: scanning

    private func isDir(_ p: String) -> Bool {
        var isD: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isD) && isD.boolValue
    }

    /// Walk `root` and call `emit` for every audio file inside a keyword folder.
    /// Return false from `emit` to abort (e.g. the client hung up mid-stream).
    private func scanIter(root: String, kws: [FolderKeyword]?, emit: ([String: Any]) -> Bool) {
        let match = segMatcher(kws)
        let rootURL = URL(fileURLWithPath: root)
        let base = rootURL.lastPathComponent
        guard let en = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return }
        // NB: don't standardize — that maps /private/tmp → /tmp and breaks the prefix match
        let rootPath = rootURL.path
        for case let url as URL in en {
            let ext = url.pathExtension.lowercased()
            guard AUDIO_EXT.contains(ext) else { continue }
            let full = url.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let rel = String(full.dropFirst(rootPath.count + 1))
            var segs = [base] + rel.components(separatedBy: "/")
            segs.removeLast()   // the file name itself doesn't count
            guard segs.contains(where: match) else { continue }   // must sit inside a configured keyword folder
            guard let st = statPath(full), st.isFile else { continue }
            let item: [String: Any] = [
                "name": url.lastPathComponent,
                "rel": base + "/" + rel,
                "abs": full,
                "ext": ext,
                "size": st.size,
                "mtime": Int64(st.mtime * 1000),
                "online": isOnlineOnly(st),
            ]
            if !emit(item) { return }
        }
    }

    private func scan(root: String, kws: [FolderKeyword]?) -> [[String: Any]] {
        var items = [[String: Any]]()
        scanIter(root: root, kws: kws) { items.append($0); return true }
        return items
    }

    // MARK: on-disk scan cache (so launch can show the last scan without re-walking)

    private func cachePath(_ root: String) -> String {
        scansDir + "/" + sha1Hex(realPathOf(root)) + ".json"
    }

    private func writeCache(root: String, items: [[String: Any]]) {
        do {
            try FileManager.default.createDirectory(atPath: scansDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["root": root, "items": items])
            try data.write(to: URL(fileURLWithPath: cachePath(root)))
        } catch {}
    }

    private func readCache(root: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: cachePath(root)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: waveform peaks (computed once per file via afconvert, cached on disk)

    private func peaksCachePath(_ path: String) -> String {
        peaksDir + "/" + sha1Hex(realPathOf(path)) + ".json"
    }

    private func getPeaks(_ path: String) -> [Double] {
        guard let st = statPath(path) else { return [] }
        let cp = peaksCachePath(path)
        if let data = FileManager.default.contents(atPath: cp),
           let c = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (c["mtime"] as? Int64 ?? Int64(c["mtime"] as? Int ?? -1)) == Int64(st.mtime),
           (c["size"] as? Int64 ?? Int64(c["size"] as? Int ?? -1)) == st.size,
           let peaks = c["peaks"] as? [Double] {
            return peaks
        }
        peaksGate.wait()
        let peaks = computePeaks(path)
        peaksGate.signal()
        do {
            try FileManager.default.createDirectory(atPath: peaksDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["mtime": Int64(st.mtime), "size": st.size, "peaks": peaks])
            try data.write(to: URL(fileURLWithPath: cp))
        } catch {}
        return peaks
    }

    private func computePeaks(_ path: String, buckets n: Int = 800) -> [Double] {
        // decode anything (wav/mp3/aiff/…) to 8 kHz mono 16-bit PCM, then bucket into n peaks
        let tmp = NSTemporaryDirectory() + "wavcave-peaks-\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@8000", "-c", "1", path, tmp]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if p.isRunning { p.terminate() } }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)),
              let samples = wavSamples(data) else { return [] }
        let total = samples.count
        if total == 0 { return [] }
        let buckets = min(n, total)
        let step = Double(total) / Double(buckets)
        var out = [Int](); out.reserveCapacity(buckets)
        var mx = 1
        for i in 0..<buckets {
            let s = Int(Double(i) * step)
            var e = Int(Double(i + 1) * step)
            if e <= s { e = s + 1 }
            var peak = 0
            for j in s..<min(e, total) {
                let v = abs(Int(samples[j]))
                if v > peak { peak = v }
            }
            out.append(peak)
            if peak > mx { mx = peak }
        }
        return out.map { (Double($0) / Double(mx) * 10000).rounded() / 10000 }
    }

    /// Extract Int16 LE samples from a RIFF/WAVE file's data chunk.
    private func wavSamples(_ data: Data) -> [Int16]? {
        guard data.count > 44,
              data.subdata(in: 0..<4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        var off = 12
        while off + 8 <= data.count {
            let id = data.subdata(in: off..<(off + 4))
            let size = Int(UInt32(data[off + 4]) | UInt32(data[off + 5]) << 8 | UInt32(data[off + 6]) << 16 | UInt32(data[off + 7]) << 24)
            let payload = off + 8
            if id == Data("data".utf8) {
                let end = min(payload + size, data.count)
                let count = (end - payload) / 2
                var samples = [Int16](repeating: 0, count: count)
                data.subdata(in: payload..<(payload + count * 2)).withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    for i in 0..<count { samples[i] = Int16(littleEndian: src[i]) }
                }
                return samples
            }
            off = payload + size + (size % 2)   // chunks are word-aligned
        }
        return nil
    }
}
