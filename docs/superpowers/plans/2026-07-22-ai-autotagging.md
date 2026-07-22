# AI Auto-Tagging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag songs with genre + mood by sending a short audio clip of each song's main version to Gemini, surfacing the results as ✦-marked AI tags alongside manual tags.

**Architecture:** A new `GET /api/autotag?path=…` endpoint in `native/Server.swift` clips ~45 s of audio via AVFoundation, calls Gemini `generateContent` with the clip inline, validates the reply against a hardcoded taxonomy, and returns `{tags:{genres,moods}}`. The frontend (`index.html`) stores AI tags in a new `bf_ai_tags` localStorage map (mirrored to disk by the existing state sync), renders them merged with manual tags, and drives per-song + batch tagging.

**Tech Stack:** Swift (Foundation, AVFoundation, URLSession), vanilla JS in the single-file `index.html`, pytest for backend tests.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-22-ai-autotagging-design.md`.
- No third-party dependencies anywhere: Swift stdlib + system frameworks only; the UI stays one self-contained `index.html`.
- Backend test command: `.venv/bin/python -m pytest tests/ -v` from the repo root (builds the server with `xcrun swiftc` — first run takes ~1 min).
- Every `/api/*` route requires the loopback Host header and (when set) the `?t=<token>` query token; the new endpoint must too (it gets this for free from `route()`).
- Manual tags (`bf_tags`) are NEVER written by any auto-tagging code path. AI tags live only in `bf_ai_tags`.
- Gemini model is the single constant `GEMINI_MODEL = "gemini-2.5-flash"` in `Server.swift`. Env overrides: `BF_GEMINI_BASE` (API base URL, for tests), `BF_GEMINI_KEY` (API key, for dev/tests; production key comes from `state.json` key `bf_gemini_key`).
- Error contract from `/api/autotag` (JSON body always has `error` and `kind`): `forbidden`→403, `no_key`→400, `decode_failed`→500, `rate_limited`→429, `offline`→502, `provider_error`→502. Success: 200 `{"tags":{"genres":[…],"moods":[…]}}`.
- Frontend code style: match the existing file — compact single-line helpers, `$()` for getElementById, `esc()` for HTML escaping, try/catch-wrapped localStorage access.

---

### Task 1: Test-harness support (extra env + fake Gemini)

**Files:**
- Modify: `tests/test_server.py` (the `Server` class, ~line 60; add stub + fixtures near the other fixtures)

**Interfaces:**
- Produces: `Server(binary, root, data_dir, token, extra_env=None)`; `FakeGemini` class with mutable `status` (int), `reply_text` (str), `raw_body` (dict or None — overrides the canned candidates wrapper), `last_request` (dict, captured); fixtures `gemini` (session-scoped FakeGemini), `ai_library` (its own root with `Bounces/good.wav` + `Bounces/bad.wav`), `ai_srv` (session-scoped Server wired to the stub via `BF_GEMINI_BASE`/`BF_GEMINI_KEY="test-gemini-key"`, with `ai_library` already scanned).

- [ ] **Step 1: Add `extra_env` to the `Server` test class**

In `tests/test_server.py`, change the `Server.__init__` signature and env construction:

```python
class Server:
    def __init__(self, binary, root, data_dir, token, extra_env=None):
        self.port = free_port()
        self.token = token
        env = dict(os.environ, BF_PORT=str(self.port), BF_ROOT=str(root),
                   BF_DATA_DIR=str(data_dir), BF_TOKEN=token)
        if extra_env:
            env.update(extra_env)
```

(The rest of `__init__` is unchanged.)

- [ ] **Step 2: Add the FakeGemini stub + fixtures**

Add to the imports at the top of `tests/test_server.py`: `import threading` and `from http.server import BaseHTTPRequestHandler, HTTPServer`.

Add after the `srv` fixture:

```python
# ---------- fake Gemini backend ----------

class FakeGemini:
    """Tiny local stand-in for the Gemini generateContent API.

    Tests mutate .status / .reply_text / .raw_body to script the next reply,
    and read .last_request to assert what the backend sent.
    """
    def __init__(self):
        self.status = 200
        self.reply_text = json.dumps({"genres": ["house"], "moods": ["dark"]})
        self.raw_body = None
        self.last_request = None
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                try:
                    fake.last_request = json.loads(self.rfile.read(n))
                except Exception:
                    fake.last_request = None
                if fake.raw_body is not None:
                    body = fake.raw_body
                else:
                    body = {"candidates": [{"content": {"parts": [{"text": fake.reply_text}]}}]}
                data = json.dumps(body).encode()
                self.send_response(fake.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *a):
                pass

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.base = "http://127.0.0.1:%d" % self.port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def reset(self):
        self.status = 200
        self.reply_text = json.dumps({"genres": ["house"], "moods": ["dark"]})
        self.raw_body = None
        self.last_request = None

    def stop(self):
        self.httpd.shutdown()


@pytest.fixture(scope="session")
def gemini():
    g = FakeGemini()
    yield g
    g.stop()


@pytest.fixture(scope="session")
def ai_library(tmp_path_factory):
    lib = tmp_path_factory.mktemp("ai_library")
    make_wav(str(lib / "SongX/Bounces/song x.wav"), seconds=2)
    bad = lib / "SongX/Bounces/bad.wav"
    bad.write_bytes(b"this is not audio at all, just junk bytes")
    return lib


@pytest.fixture(scope="session")
def ai_srv(server_bin, ai_library, gemini, tmp_path_factory):
    static = tmp_path_factory.mktemp("ai_static")
    (static / "index.html").write_text("<html>wavcave test</html>")
    data = tmp_path_factory.mktemp("ai_data")
    s = Server(server_bin, static, data, TOKEN,
               extra_env={"BF_GEMINI_BASE": gemini.base, "BF_GEMINI_KEY": "test-gemini-key"})
    s.library = ai_library
    s.data_dir = data
    s.get_json("/api/scan", path=str(ai_library))   # allow-lists the library for /api/autotag
    yield s
    s.stop()


def get_json_err(srv, route, **params):
    """GET a route expected to fail; return (http_status, parsed_json_body)."""
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get(route, **params)
    return e.value.code, json.loads(e.value.read())


def test_fake_gemini_stub_works(gemini):
    gemini.reset()
    req = urllib.request.Request(gemini.base + "/v1beta/models/x:generateContent",
                                 data=b'{"contents":[]}', method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        j = json.loads(r.read())
    assert "house" in j["candidates"][0]["content"]["parts"][0]["text"]
    assert gemini.last_request == {"contents": []}
```

- [ ] **Step 3: Run the suite to confirm it's green**

Run: `.venv/bin/python -m pytest tests/ -v`
Expected: all existing tests PASS plus `test_fake_gemini_stub_works` PASS. (`ai_srv` isn't used by any test yet — fixtures only instantiate when requested.)

- [ ] **Step 4: Commit**

```bash
git add tests/test_server.py
git commit -m "test: harness support for autotag — extra env + fake Gemini stub"
```

---

### Task 2: Backend `/api/autotag` endpoint

**Files:**
- Modify: `native/Server.swift`
- Test: `tests/test_server.py`

**Interfaces:**
- Consumes: `gemini`, `ai_srv`, `ai_library`, `get_json_err` from Task 1.
- Produces: `GET /api/autotag?path=<abs>` per the Global Constraints error contract. File-private Swift symbols: `GEMINI_MODEL: String`, `AI_GENRES: [String]`, `AI_MOODS: [String]`, `autotagPrompt() -> String`, and methods `apiAutotag(_:_:)`, `geminiAPIKey() -> String?`, `exportSnippet(_:) -> Data?`, `callGemini(apiKey:audio:) -> (code: Int, body: Data)?`, `parseTags(_:) -> (genres: [String], moods: [String])?` on `WavCaveServer`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_server.py`:

```python
# ---------- AI auto-tagging ----------

def autotag(srv, path):
    return srv.get_json("/api/autotag", path=str(path))


def good_wav(srv):
    return srv.library / "SongX/Bounces/song x.wav"


def test_autotag_requires_token(ai_srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        ai_srv.get("/api/autotag", with_token=False, path=str(good_wav(ai_srv)))
    assert e.value.code == 401


def test_autotag_path_outside_roots_forbidden(ai_srv):
    code, j = get_json_err(ai_srv, "/api/autotag", path="/etc/hosts")
    assert code == 403 and j["kind"] == "forbidden"


def test_autotag_happy_path(ai_srv, gemini):
    gemini.reset()
    gemini.reply_text = json.dumps({"genres": ["house", "deep house"], "moods": ["dark"]})
    j = autotag(ai_srv, good_wav(ai_srv))
    assert j == {"tags": {"genres": ["house", "deep house"], "moods": ["dark"]}}
    # the backend really sent audio inline
    parts = gemini.last_request["contents"][0]["parts"]
    inline = [p for p in parts if "inline_data" in p]
    assert inline and inline[0]["inline_data"]["mime_type"] == "audio/mp4"
    assert len(inline[0]["inline_data"]["data"]) > 1000
    # and asked for JSON out
    assert gemini.last_request["generationConfig"]["response_mime_type"] == "application/json"


def test_autotag_filters_and_lowercases(ai_srv, gemini):
    gemini.reset()
    gemini.reply_text = json.dumps({"genres": ["HOUSE", "notarealgenre", "techno", "trance"],
                                    "moods": ["dark", "sparkly"]})
    j = autotag(ai_srv, good_wav(ai_srv))
    # lowercased, out-of-taxonomy dropped, capped at 2
    assert j["tags"] == {"genres": ["house", "techno"], "moods": ["dark"]}


def test_autotag_strips_code_fences(ai_srv, gemini):
    gemini.reset()
    gemini.reply_text = "```json\n" + json.dumps({"genres": ["ambient"], "moods": []}) + "\n```"
    j = autotag(ai_srv, good_wav(ai_srv))
    assert j["tags"]["genres"] == ["ambient"]


def test_autotag_junk_reply_is_provider_error(ai_srv, gemini):
    gemini.reset()
    gemini.reply_text = "sorry, I cannot help with that"
    code, j = get_json_err(ai_srv, "/api/autotag", path=str(good_wav(ai_srv)))
    assert code == 502 and j["kind"] == "provider_error"


def test_autotag_rate_limited(ai_srv, gemini):
    gemini.reset()
    gemini.status = 429
    gemini.raw_body = {"error": {"message": "quota"}}
    code, j = get_json_err(ai_srv, "/api/autotag", path=str(good_wav(ai_srv)))
    assert code == 429 and j["kind"] == "rate_limited"
    gemini.reset()


def test_autotag_undecodable_file(ai_srv, gemini):
    gemini.reset()
    code, j = get_json_err(ai_srv, "/api/autotag", path=str(ai_srv.library / "SongX/Bounces/bad.wav"))
    assert code == 500 and j["kind"] == "decode_failed"


def test_autotag_no_key(server_bin, ai_library, gemini, tmp_path_factory):
    static = tmp_path_factory.mktemp("nk_static")
    (static / "index.html").write_text("x")
    s = Server(server_bin, static, tmp_path_factory.mktemp("nk_data"), TOKEN,
               extra_env={"BF_GEMINI_BASE": gemini.base})   # no BF_GEMINI_KEY, empty state.json
    try:
        s.get_json("/api/scan", path=str(ai_library))
        code, j = get_json_err(s, "/api/autotag", path=str(ai_library / "SongX/Bounces/song x.wav"))
        assert code == 400 and j["kind"] == "no_key"
    finally:
        s.stop()
```

- [ ] **Step 2: Run to verify they fail**

Run: `.venv/bin/python -m pytest tests/ -v -k autotag`
Expected: FAIL — `/api/autotag` currently falls through to `serveStatic` and 404s, so every test errors with an unexpected HTTPError 404.

- [ ] **Step 3: Implement in `native/Server.swift`**

3a. Change the import block at the top of the file (after the header comment) to add AVFoundation:

```swift
import Foundation
import CryptoKit
import Darwin
import AVFoundation
```

3b. Add the taxonomy + model constants and prompt right after `private let DEFAULT_KEYWORDS…` (file scope):

```swift
// MARK: - AI auto-tagging (Gemini)

let GEMINI_MODEL = "gemini-2.5-flash"

// Controlled taxonomy: the model must pick from these lists, and anything else
// it replies with is dropped, so tag filters never fragment into variant spellings.
let AI_GENRES = ["hip hop", "trap", "drill", "boom bap", "lo-fi", "r&b", "soul", "funk",
                 "pop", "indie pop", "rock", "indie rock", "punk", "metal", "folk", "country",
                 "singer-songwriter", "jazz", "blues", "gospel", "classical", "cinematic",
                 "ambient", "house", "deep house", "tech house", "techno", "trance", "dubstep",
                 "drum and bass", "garage", "breakbeat", "electro", "synthwave", "edm",
                 "disco", "reggae", "dancehall", "afrobeats", "latin", "world"]
let AI_MOODS = ["dark", "moody", "uplifting", "chill", "aggressive", "melancholic",
                "dreamy", "energetic", "hypnotic", "playful", "epic", "romantic"]

func autotagPrompt() -> String {
    return """
    You are tagging a music producer's own unreleased track. Listen to the audio and reply \
    with STRICT JSON only, no prose, exactly in the form {"genres": [...], "moods": [...]}.
    Pick 1-2 genres, only from this list: \(AI_GENRES.joined(separator: ", ")).
    Pick 1-2 moods, only from this list: \(AI_MOODS.joined(separator: ", ")).
    Use the exact lowercase spellings from the lists.
    """
}
```

3c. Register the route: in `route(_:_:)`, add one line to the GET `switch` (after `case "/api/file":`):

```swift
        case "/api/autotag":    apiAutotag(req, fd)
```

3d. Add the endpoint + helpers to `WavCaveServer` (put them after `apiFree`, before `// MARK: static files`):

```swift
    // MARK: AI auto-tagging

    /// Gemini API key: env override (dev/tests) else the UI-saved value in state.json.
    private func geminiAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let k = env["BF_GEMINI_KEY"], !k.isEmpty { return k }
        if let data = FileManager.default.contents(atPath: stateFile),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let k = obj["bf_gemini_key"] as? String, !k.isEmpty { return k }
        return nil
    }

    /// Export a ~45 s mono-ish AAC clip from the middle of the track (whole track if shorter).
    private func exportSnippet(_ path: String) -> Data? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let dur = CMTimeGetSeconds(asset.duration)
        guard dur.isFinite, dur > 0,
              let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let win = min(45.0, dur)
        let start = max(0, (dur - win) / 2)
        let tmp = NSTemporaryDirectory() + "wavcave-clip-\(UUID().uuidString).m4a"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        ex.outputURL = URL(fileURLWithPath: tmp)
        ex.outputFileType = .m4a
        ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                   duration: CMTime(seconds: win, preferredTimescale: 600))
        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        sem.wait()
        guard ex.status == .completed else { return nil }
        return FileManager.default.contents(atPath: tmp)
    }

    /// One provider call, isolated so a second provider can slot in later.
    private func callGemini(apiKey: String, audio: Data) -> (code: Int, body: Data)? {
        let base = ProcessInfo.processInfo.environment["BF_GEMINI_BASE"]
            ?? "https://generativelanguage.googleapis.com"
        guard let url = URL(string: "\(base)/v1beta/models/\(GEMINI_MODEL):generateContent") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let payload: [String: Any] = [
            "contents": [["parts": [
                ["text": autotagPrompt()],
                ["inline_data": ["mime_type": "audio/mp4", "data": audio.base64EncodedString()]],
            ]]],
            "generationConfig": ["temperature": 0.2, "response_mime_type": "application/json"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        var out: (Int, Data)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, let d = data { out = (http.statusCode, d) }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    /// Pull the model's text out of a generateContent reply and validate it
    /// against the taxonomy. nil means the reply was unusable.
    private func parseTags(_ body: Data) -> (genres: [String], moods: [String])? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              var text = parts.first?["text"] as? String else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let d = text.data(using: .utf8),
              let t = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let g = ((t["genres"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
            .filter { AI_GENRES.contains($0) }
        let m = ((t["moods"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
            .filter { AI_MOODS.contains($0) }
        if g.isEmpty && m.isEmpty { return nil }
        return (Array(g.prefix(2)), Array(m.prefix(2)))
    }

    private func apiAutotag(_ req: HTTPRequest, _ fd: Int32) {
        guard let t = req.query["path"], !t.isEmpty, isAllowedPath(t),
              let st = statPath(t), st.isFile else {
            return sendJSON(fd, ["error": "forbidden", "kind": "forbidden"], code: 403)
        }
        guard let key = geminiAPIKey() else {
            return sendJSON(fd, ["error": "no Gemini API key configured", "kind": "no_key"], code: 400)
        }
        guard let clip = exportSnippet(t) else {
            return sendJSON(fd, ["error": "could not decode audio", "kind": "decode_failed"], code: 500)
        }
        guard let (code, body) = callGemini(apiKey: key, audio: clip) else {
            return sendJSON(fd, ["error": "network unreachable", "kind": "offline"], code: 502)
        }
        if code == 429 {
            return sendJSON(fd, ["error": "rate limited", "kind": "rate_limited"], code: 429)
        }
        guard code == 200, let tags = parseTags(body) else {
            return sendJSON(fd, ["error": "provider error (HTTP \(code))", "kind": "provider_error"], code: 502)
        }
        sendJSON(fd, ["tags": ["genres": tags.genres, "moods": tags.moods]])
    }
```

- [ ] **Step 4: Run the autotag tests**

Run: `.venv/bin/python -m pytest tests/ -v -k autotag`
Expected: all PASS. (Deprecation warnings from `asset.duration` / `exportAsynchronously` during the swiftc build are fine.)

- [ ] **Step 5: Run the full suite**

Run: `.venv/bin/python -m pytest tests/ -v`
Expected: all PASS — the new route must not disturb existing endpoints.

- [ ] **Step 6: Commit**

```bash
git add native/Server.swift tests/test_server.py
git commit -m "feat: /api/autotag — Gemini genre+mood tagging over a 45s AVFoundation clip"
```

---

### Task 3: Frontend AI-tag storage + display

**Files:**
- Modify: `index.html` (storage block ~line 838, `combineKeys` ~line 847, search filter ~line 935, ctx sub ~line 1521, tag picker `showTagPicker` ~line 1488, detail panel `openDetail` ~line 1888, init calls ~lines 2104+2110, CSS ~line 437)

**Interfaces:**
- Consumes: existing `songTags`, `groupKey`, `esc`, `render`, `refreshDetailIfOpen`.
- Produces: `aiTags` (Map songKey→[tags]), `loadAiTags()`, `saveAiTags()`, `tagsOf(key) -> [string]` (manual tags then non-duplicate AI tags). Task 4/5 call `aiTags`, `saveAiTags`, `tagsOf`.

- [ ] **Step 1: Add the storage trio + merged accessor**

In `index.html`, directly after the `saveTags` line (`const saveTags = () => …bf_tags…`), insert:

```js
  const aiTags = new Map();   // songKey -> [AI tags]; re-runs replace these, manual bf_tags is never touched
  const loadAiTags = () => { try{ const o=JSON.parse(localStorage.getItem("bf_ai_tags")||"{}"); for(const k in o) if(Array.isArray(o[k])) aiTags.set(k,o[k]); }catch(e){} };
  const saveAiTags = () => { try{ const o={}; aiTags.forEach((v,k)=>{ if(v&&v.length) o[k]=v; }); localStorage.setItem("bf_ai_tags", JSON.stringify(o)); }catch(e){} };
  const tagsOf = (key) => { const man=songTags.get(key)||[]; const low=new Set(man.map(t=>t.toLowerCase())); return man.concat((aiTags.get(key)||[]).filter(t=>!low.has(t.toLowerCase()))); };
```

- [ ] **Step 2: Wire init + merge**

2a. There are two init call sites (search for `loadCollections(); loadTags();` — it appears twice, ~lines 2104 and 2110). In BOTH, change `loadTags();` to `loadTags(); loadAiTags();`.

2b. In `combineKeys(keys)`, after the existing `songTags` carry-over block (`const t=songTags.get(k); if (t&&t.length){ … }`), add the same for AI tags:

```js
      const at=aiTags.get(k);
      if (at&&at.length){ const cur=aiTags.get(canon)||[]; for(const x of at) if(!cur.some(y=>y.toLowerCase()===x.toLowerCase())) cur.push(x); aiTags.set(canon,cur); aiTags.delete(k); }
```

2c. In the same function's save line (`saveMerges(); saveFavs(); saveTags(); …`), add `saveAiTags();` after `saveTags();`.

- [ ] **Step 3: Merge AI tags into search + context-menu subtitle**

3a. Search token filter (~line 935): replace

```js
    if (tok.tag) out=out.filter(f=>{ const t=songTags.get(groupKey(f.name))||[]; return t.some(x=>x.toLowerCase().includes(tok.tag)); });
```

with

```js
    if (tok.tag) out=out.filter(f=>{ const t=tagsOf(groupKey(f.name)); return t.some(x=>x.toLowerCase().includes(tok.tag)); });
```

3b. Context-menu subtitle (~line 1521): in `showCtx`, replace `const _tg=songTags.get(_ks)||[];` with `const _tg=tagsOf(_ks);`.

- [ ] **Step 4: Detail panel — ✦ chips**

In `openDetail` (~line 1888), replace `const tags=songTags.get(key)||[];` with:

```js
    const tags=songTags.get(key)||[];
    const ai=(aiTags.get(key)||[]).filter(t=>!tags.some(y=>y.toLowerCase()===t.toLowerCase()));
```

Then replace the Tags section line (the one building `<div class="dt-sec">Tags</div>…`) with:

```js
      + `<div class="dt-sec">Tags</div><div class="dt-chips">${tags.map(t=>`<span class="dt-chip tag">${esc(t)}</span>`).join("")}${ai.map(t=>`<span class="dt-chip tag ai">✦ ${esc(t)}</span>`).join("")}${(tags.length||ai.length)?"":'<span class="dt-dim">None</span>'} <button class="dt-add" id="dtEditTags">edit…</button></div>`
```

Add CSS after the existing `.dt-chip.tag{…}` rule (~line 437):

```css
  .dt-chip.tag.ai{ opacity:.8; }
  .ctx-tag.ai{ opacity:.85; }
```

- [ ] **Step 5: Tag picker — show, delete, and promote AI tags**

In `showTagPicker` (~line 1488):

5a. After `const cur=songTags.get(key)||[];` add: `const curAi=aiTags.get(key)||[];`

5b. In the `ctx.innerHTML` template, after the known-tags chips block (the `(opts.length? … :"")` expression) and before the Done row, insert:

```js
      + (curAi.length?`<div class="ctx-head" style="padding-top:6px">AI tags — click to remove</div><div class="ctx-tags">${curAi.map(t=>`<button type="button" class="ctx-tag on ai" data-ai="${esc(t)}">✦ ${esc(t)}</button>`).join("")}</div>`:"")
```

5c. Replace the `save` function with a version that promotes typed duplicates out of the AI pool:

```js
    const save=()=>{ const t=parse(); if(t.length) songTags.set(key,t); else songTags.delete(key);
      const low=new Set(t.map(x=>x.toLowerCase()));
      const keptAi=(aiTags.get(key)||[]).filter(x=>!low.has(x.toLowerCase()));
      if(keptAi.length) aiTags.set(key,keptAi); else aiTags.delete(key);
      saveTags(); saveAiTags(); render(); refreshDetailIfOpen(rec); };
```

5d. After the existing `.ctx-tag` click wiring, add the AI-chip remove handler:

```js
    ctx.querySelectorAll("[data-ai]").forEach(b=>b.onclick=()=>{ const t=b.dataset.ai; const list=(aiTags.get(key)||[]).filter(x=>x!==t); if(list.length) aiTags.set(key,list); else aiTags.delete(key); saveAiTags(); render(); refreshDetailIfOpen(rec); showTagPicker(rec,pos); });
```

- [ ] **Step 6: Verify manually**

```sh
cd native && xcrun swiftc -parse-as-library Server.swift server-cli.swift -o wavcave-server && BF_ROOT="$(pwd)/.." ./wavcave-server
```

Open http://127.0.0.1:8765, then in the browser console:
`localStorage.setItem("bf_ai_tags", JSON.stringify({"<some songKey>": ["house","dark"]}))` — get a real key via right-click → Song details on any song, or from `localStorage.getItem("bf_tags")`. Reload. Check: ✦ house / ✦ dark chips in the song's detail panel; `tag:house` in the search box finds it; the tag picker shows the AI chips, clicking one removes it, and typing `house` into the input then Done moves it to a plain manual chip. Kill the server after.

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "feat: AI tag pool (bf_ai_tags) — merged display, search, picker delete/promote"
```

---

### Task 4: Settings key entry + per-song "Auto-tag with AI"

**Files:**
- Modify: `index.html` (settings HTML ~line 764, `openSettings` ~line 2073, wiring block ~line 2095, `showCtx` ~line 1523, new functions near `showTagPicker`)

**Interfaces:**
- Consumes: `aiTags`, `saveAiTags` (Task 3); existing `allGroups`, `groupKey`, `songTitle`, `api`, `status`, `openSettings`, `_syncState`, `DEMO`.
- Produces: `mainVersionOf(key) -> file|null`, `autotagKey(key) -> Promise<{kind:string}>` (`kind` is `"ok"` or an error kind from the endpoint contract), `sleep(ms)`. Task 5 reuses all three.

- [ ] **Step 1: Settings section HTML**

In the settings drawer (~line 764), directly BEFORE `<div class="set-sec-title" style="margin-top:26px;">Software</div>`, insert:

```html
    <div class="set-sec-title" style="margin-top:26px;">AI auto-tagging</div>
    <p class="set-sub">Tags songs by genre and mood by sending a short clip of each song to Google Gemini. Needs a free API key from <a href="https://aistudio.google.com/apikey" target="_blank" rel="noreferrer">Google AI Studio</a>. Audio leaves your machine only when you run it.</p>
    <input id="setGeminiKey" class="kw-word" style="width:100%;" type="password" placeholder="Gemini API key…" spellcheck="false" autocomplete="off" />
    <button class="btn" id="setTagLibrary" style="margin-top:12px;"><span class="sf sf-wave"></span>Tag library with AI</button>
    <p class="set-note" id="setTagMsg"></p>
```

- [ ] **Step 2: Key persistence + settings wiring**

2a. In `openSettings()` (~line 2073), after `_kwSnap=JSON.stringify(keywords); renderKwEditor($("settingsKw"));` add:

```js
    { const gk=$("setGeminiKey"); if(gk) gk.value=localStorage.getItem("bf_gemini_key")||""; }
```

2b. In the wiring block near `{ const b=$("setClose"); … }` (~line 2095), add:

```js
  { const k=$("setGeminiKey"); if(k) k.addEventListener("change", ()=>{ const v=k.value.trim(); if(v) localStorage.setItem("bf_gemini_key", v); else localStorage.removeItem("bf_gemini_key"); _syncState(); }); }
```

(`_syncState()` is called explicitly because the backend reads the key from `state.json` and `removeItem` isn't hooked by the auto-sync; this also beats the 400 ms debounce race on first use.)

- [ ] **Step 3: Core helpers `mainVersionOf` / `autotagKey` / `sleep`**

Insert directly before `function showCtx(x,y,rec){` (~line 1508):

```js
  /* ---------- AI auto-tagging ---------- */
  const sleep=(ms)=>new Promise(r=>setTimeout(r,ms));
  function mainVersionOf(key){ const g=allGroups().find(x=>x.key===key); return g?g.head:null; }
  // One song: clip + Gemini happen server-side; on success the AI pool for the
  // song is REPLACED (manual tags untouched). Returns {kind:"ok"} or an error kind.
  async function autotagKey(key){
    const head=mainVersionOf(key); if(!head) return {kind:"skipped"};
    let r;
    try { r=await fetch(api("/api/autotag?path="+encodeURIComponent(head.abs))); }
    catch(e){ return {kind:"offline"}; }
    let j={}; try{ j=await r.json(); }catch(e){}
    if(r.ok && j.tags){
      const list=[...(j.tags.genres||[]),...(j.tags.moods||[])];
      if(list.length){ aiTags.set(key,list); saveAiTags(); }
      return {kind:"ok"};
    }
    return {kind:j.kind||"provider_error"};
  }
  const autotagErrMsg=(kind)=>({rate_limited:"rate limited — try again shortly", decode_failed:"couldn’t decode the audio", offline:"no internet connection", provider_error:"the AI service returned an error"}[kind]||kind);
```

- [ ] **Step 4: Context-menu item**

4a. In `showCtx`, after the `setartist` line (`html+=…data-act="setartist"…`), add:

```js
    { const _atg=aiTags.get(groupKey(rec.name))||[];
      html+=`<div class="ctx-item" data-act="autotag"><span class="ctx-line"><span class="sf sf-wave"></span>Auto-tag with AI</span>${_atg.length?`<span class="ctx-sub">✦ ${esc(_atg.slice(0,3).join(", "))}</span>`:""}</div>`; }
```

4b. With the other handlers (after `ctx.querySelector('[data-act=setartist]')…`), add:

```js
    ctx.querySelector('[data-act=autotag]').onclick=async()=>{ hideCtx();
      if(DEMO){ status("Auto-tagging isn’t available in the demo."); return; }
      if(!localStorage.getItem("bf_gemini_key")){ openSettings(); status("Add a Gemini API key in Settings to use AI auto-tagging."); return; }
      status("Listening to “"+songTitle(rec)+"”…");
      const res=await autotagKey(groupKey(rec.name));
      if(res.kind==="ok"){ render(); refreshDetailIfOpen(rec); status("Tagged “"+songTitle(rec)+"”."); }
      else if(res.kind==="no_key"){ openSettings(); status("Add a Gemini API key in Settings to use AI auto-tagging."); }
      else status("Auto-tag failed: "+autotagErrMsg(res.kind)+".");
    };
```

Note: `openSettings` is declared later in the file via `function` hoisting within the same IIFE — calling it here is fine (same pattern as other early references).

- [ ] **Step 5: Verify manually**

Rebuild + run the dev server as in Task 3 step 6, but export a real key first: `BF_GEMINI_KEY` is backend-only, so instead paste a real Gemini key in Settings (or, keyless, verify the no-key path: right-click a song → Auto-tag with AI → Settings opens with the key prompt). With a key: right-click → Auto-tag with AI on a real bounce → status shows "Listening…", then ✦ tags appear in the detail panel. Also verify the key survives an app restart (state.json round-trip).

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "feat: per-song Auto-tag with AI + Gemini key setup in Settings"
```

---

### Task 5: Batch "Tag library with AI"

**Files:**
- Modify: `index.html` (below the Task 4 helpers; `openSettings`; wiring block)

**Interfaces:**
- Consumes: `autotagKey`, `sleep`, `aiTags`, `sessionSkip` (created here), `allGroups`, `status`, `openSettings`, `DEMO`.
- Produces: `tagLibrary()` (start/stop toggle), `updateBatchBtn()`.

- [ ] **Step 1: Implement the batch runner**

Directly after the `autotagErrMsg` line from Task 4, add:

```js
  const sessionSkip=new Set();   // decode_failed songs: skipped for this launch only
  let batchRun=null;             // {cancel,done,total,failed} while a batch is active
  function updateBatchBtn(){ const b=$("setTagLibrary"); if(b) b.innerHTML=batchRun?'<span class="sf sf-ban"></span>Stop tagging':'<span class="sf sf-wave"></span>Tag library with AI'; }
  const tagStatus=(m)=>{ status(m); const el=$("setTagMsg"); if(el) el.textContent=m; };
  // Batch: every song with no AI tags, 2 workers, backoff on rate limits, cancelable.
  async function tagLibrary(){
    if(batchRun){ batchRun.cancel=true; tagStatus("Stopping…"); return; }
    if(DEMO){ tagStatus("Auto-tagging isn’t available in the demo."); return; }
    if(!localStorage.getItem("bf_gemini_key")){ tagStatus("Add a Gemini API key above first."); return; }
    const keys=allGroups().map(g=>g.key).filter(k=>!(aiTags.get(k)||[]).length && !sessionSkip.has(k));
    if(!keys.length){ tagStatus("Every song already has AI tags."); return; }
    batchRun={cancel:false,done:0,total:keys.length,failed:0};
    updateBatchBtn();
    const worker=async()=>{ while(keys.length && !batchRun.cancel){
      const k=keys.shift();
      let res=await autotagKey(k), tries=0;
      while(res.kind==="rate_limited" && !batchRun.cancel && tries++<4){
        for(let s=30;s>0 && !batchRun.cancel;s--){ tagStatus(`Rate limited — resuming in ${s}s… (${batchRun.done}/${batchRun.total})`); await sleep(1000); }
        if(!batchRun.cancel) res=await autotagKey(k);
      }
      if(res.kind==="decode_failed") sessionSkip.add(k);
      if(res.kind==="no_key"){ batchRun.cancel=true; openSettings(); }
      if(res.kind!=="ok") batchRun.failed++;
      batchRun.done++;
      tagStatus(`Auto-tagging ${batchRun.done}/${batchRun.total}…`);
      if(batchRun.done%10===0) render();
    }};
    await Promise.all([worker(),worker()]);
    const done=batchRun; batchRun=null; updateBatchBtn(); render();
    tagStatus(done.cancel?`Auto-tagging stopped (${done.done} of ${done.total} processed).`:`Auto-tagging finished: ${done.done-done.failed} tagged, ${done.failed} skipped.`);
  }
```

- [ ] **Step 2: Wire the button**

2a. In the wiring block (~line 2095 area, next to the Task 4 key wiring), add:

```js
  { const b=$("setTagLibrary"); if(b) b.addEventListener("click", ()=>tagLibrary()); }
```

2b. In `openSettings()`, after the Task 4 `setGeminiKey` line, add: `updateBatchBtn();`

- [ ] **Step 3: Verify manually**

Rebuild + run the dev server against a folder with a handful of bounces, paste a key, Settings → Tag library with AI. Check: progress counts in both the footer status line and the settings note; the button flips to "Stop tagging" and cancels mid-run; a re-run reports "Every song already has AI tags." for the ones done; a corrupt `.wav` (make one with `echo junk > Bounces/bad.wav` + rescan) is skipped and counted in the summary.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "feat: batch Tag library with AI — 2 workers, rate-limit backoff, cancel"
```

---

### Task 6: Docs + final green run

**Files:**
- Modify: `README.md` (feature blurb), `docs/superpowers/specs/2026-07-22-ai-autotagging-design.md` (status line)

- [ ] **Step 1: README**

In `README.md`, in the intro paragraph, extend the feature list sentence — change `group versions, audition with a waveform, sort by artist, and more.` to `group versions, audition with a waveform, sort by artist, auto-tag genres with AI, and more.` Then after the "Layout" section's `tests/` bullet, add a short section:

```markdown
## AI auto-tagging (optional, online)
Right-click a song → **Auto-tag with AI**, or Settings → **Tag library with AI**,
to tag songs by genre + mood. This sends a ~45 s clip of each song to Google
Gemini and needs a free API key (Settings → AI auto-tagging). It is the one
feature that talks to the internet — everything else stays local.
```

- [ ] **Step 2: Spec status**

In the spec file, change `Status: Approved direction, pending spec review` to `Status: Implemented 2026-07-22`.

- [ ] **Step 3: Full suite**

Run: `.venv/bin/python -m pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-07-22-ai-autotagging-design.md
git commit -m "docs: AI auto-tagging feature notes"
```
