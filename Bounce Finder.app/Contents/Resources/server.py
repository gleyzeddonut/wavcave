#!/usr/bin/env python3
"""Bounce Finder backend: scans for bounce audio, streams it, reveals it in Finder."""
import os, json, subprocess, urllib.parse, mimetypes, re, threading, queue, wave, array, tempfile, math
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("BF_PORT", "8765"))
ROOT = os.path.dirname(os.path.abspath(__file__))   # static files live here
ALLOWED = set()                                     # folders we're allowed to read/reveal
AUDIO_EXT = {".wav", ".mp3"}
TARGET = {"bounce", "bounces"}
# Default folder keyword when the client doesn't send its own configuration.
DEFAULT_KW = [{"word": "bounce", "caseSensitive": False, "pluralize": True}]


def _plural(w):
    lw = w.lower()
    if lw.endswith(("s", "x", "z", "ch", "sh")):
        return w + "es"
    if len(w) > 1 and lw.endswith("y") and lw[-2] not in "aeiou":
        return w[:-1] + "ies"
    return w + "s"


def _seg_matcher(kws):
    """Build a fast folder-name matcher from a keyword config list.
    Each keyword: {word, caseSensitive, pluralize}. Returns match(seg)->bool."""
    cs_set, ci_set = set(), set()          # case-sensitive exact / case-insensitive exact
    for kw in (kws or DEFAULT_KW):
        w = (kw.get("word") or "").strip()
        if not w:
            continue
        cands = [w]
        if kw.get("pluralize"):
            p = _plural(w)
            if p != w:
                cands.append(p)
        for c in cands:
            if kw.get("caseSensitive"):
                cs_set.add(c)
            else:
                ci_set.add(c.lower())
    if not cs_set and not ci_set:          # nothing valid -> fall back to default
        for kw in DEFAULT_KW:
            ci_set.add(kw["word"].lower())
            ci_set.add(_plural(kw["word"]).lower())

    def match(seg):
        return seg in cs_set or seg.lower() in ci_set
    return match
# All persisted data lives here (overridable so tests never touch the real library).
DATA_DIR = os.environ.get("BF_DATA_DIR", os.path.expanduser("~/Library/Application Support/BounceFinder"))


def is_online_only(st):
    """True if the file's bytes aren't on disk yet (e.g. a Dropbox online-only placeholder)."""
    return st.st_size > 0 and getattr(st, "st_blocks", 0) * 512 < st.st_size


# --- prefetch worker pool: reading a cloud file forces it to download ---
_pf_queue = queue.Queue()
_pf_seen = set()
_pf_lock = threading.Lock()


def _pf_worker():
    while True:
        path = _pf_queue.get()
        try:
            with open(path, "rb") as f:
                while f.read(1 << 20):
                    pass
        except Exception:
            pass
        finally:
            with _pf_lock:
                _pf_seen.discard(path)
            _pf_queue.task_done()


for _ in range(3):
    threading.Thread(target=_pf_worker, daemon=True).start()


def choose_folder():
    script = 'POSIX path of (choose folder with prompt "Choose a folder to search for bounce files:")'
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=600)
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return None


def _scan_iter(root, kws=None):
    match = _seg_matcher(kws)
    base = os.path.basename(os.path.normpath(root))
    for dp, _dn, fns in os.walk(root):
        for fn in fns:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in AUDIO_EXT:
                continue
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root)
            segs = [base] + rel.split(os.sep)
            if not any(match(s) for s in segs[:-1]):   # must sit inside a configured keyword folder
                continue
            try:
                st = os.stat(full)
            except OSError:
                continue
            yield {
                "name": fn,
                "rel": base + "/" + rel.replace(os.sep, "/"),
                "abs": full,
                "ext": ext[1:],
                "size": st.st_size,
                "mtime": int(st.st_mtime * 1000),
                "online": is_online_only(st),
            }


def scan(root, kws=None):
    return list(_scan_iter(root, kws))


def _parse_kw(q):
    raw = (q.get("kw") or [None])[0]
    if not raw:
        return None
    try:
        v = json.loads(raw)
        return v if isinstance(v, list) else None
    except Exception:
        return None


# --- on-disk scan cache (so launch can show the last scan without re-walking) ---
import hashlib
CACHE_DIR = os.path.join(DATA_DIR, "scans")


def _cache_path(root):
    h = hashlib.sha1(os.path.realpath(root).encode("utf-8")).hexdigest()
    return os.path.join(CACHE_DIR, h + ".json")


def write_cache(root, items):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(_cache_path(root), "w") as f:
            json.dump({"root": root, "items": items}, f)
    except Exception:
        pass


def read_cache(root):
    try:
        with open(_cache_path(root)) as f:
            return json.load(f)
    except Exception:
        return None


# --- durable user state (filters, ignores, joins, stars, pins, artist edits, roots…) ---
STATE_FILE = os.path.join(DATA_DIR, "state.json")

# --- waveform peaks: computed once per file (any format, via afconvert) and cached on disk ---
PEAKS_DIR = os.path.join(DATA_DIR, "peaks")
PEAKS_N = 800


def _peaks_path(path):
    h = hashlib.sha1(os.path.realpath(path).encode("utf-8")).hexdigest()
    return os.path.join(PEAKS_DIR, h + ".json")


def _compute_peaks(path, n=PEAKS_N):
    # decode anything (wav/mp3/aiff/…) to 8 kHz mono 16-bit PCM, then bucket into n peaks
    tmp = tempfile.mktemp(suffix=".wav")
    try:
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@8000", "-c", "1", path, tmp],
                       check=True, capture_output=True, timeout=180)
        w = wave.open(tmp, "rb")
        raw = w.readframes(w.getnframes())
        w.close()
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    a = array.array("h")
    a.frombytes(raw)
    total = len(a)
    if not total:
        return {"peaks": [], "rms": 0.0}
    buckets = min(n, total)
    step = total / float(buckets)
    out, mx = [], 1
    for i in range(buckets):
        s = int(i * step)
        e = int((i + 1) * step)
        if e <= s:
            e = s + 1
        seg = a[s:e]
        p = max(max(seg), -min(seg))
        out.append(p)
        if p > mx:
            mx = p
    # linear RMS (0..1) for loudness matching — sampled for speed
    ss = cnt = 0
    for x in a[::2]:
        ss += x * x
        cnt += 1
    rms = (math.sqrt(ss / cnt) / 32768.0) if cnt else 0.0
    return {"peaks": [round(p / mx, 4) for p in out], "rms": round(rms, 6)}


def get_peaks(path):
    try:
        st = os.stat(path)
        cp = _peaks_path(path)
        try:
            with open(cp) as f:
                c = json.load(f)
            if c.get("mtime") == int(st.st_mtime) and c.get("size") == st.st_size:
                return {"peaks": c.get("peaks", []), "rms": c.get("rms", 0.0)}
        except Exception:
            pass
        res = _compute_peaks(path)
        try:
            os.makedirs(PEAKS_DIR, exist_ok=True)
            with open(cp, "w") as f:
                json.dump({"mtime": int(st.st_mtime), "size": st.st_size,
                           "peaks": res["peaks"], "rms": res["rms"]}, f)
        except Exception:
            pass
        return res
    except Exception:
        return {"peaks": [], "rms": 0.0}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, ctype, body=b"", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, "application/json", json.dumps(obj).encode())

    def _allowed(self, p):
        try:
            rp = os.path.realpath(p)
        except Exception:
            return False
        return any(rp == r or rp.startswith(r + os.sep) for r in ALLOWED)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        p = u.path
        if p == "/api/ping":
            return self._json({"ok": True})
        if p == "/api/pick":
            f = choose_folder()
            if not f:
                return self._json({"cancelled": True})
            ALLOWED.add(os.path.realpath(f))
            return self._json({"path": f})
        if p == "/api/scan":
            root = (q.get("path") or [""])[0]
            if not root or not os.path.isdir(root):
                return self._json({"error": "Folder not found"}, 400)
            ALLOWED.add(os.path.realpath(root))
            try:
                items = scan(root, _parse_kw(q))
                write_cache(root, items)
                return self._json({"root": root, "items": items})
            except Exception as e:
                return self._json({"error": str(e)}, 500)
        if p == "/api/scan_stream":
            # NDJSON stream: one {"item":…} line per file as it's discovered,
            # then a final {"done":true,…}. Lets the UI tick the count per file.
            root = (q.get("path") or [""])[0]
            if not root or not os.path.isdir(root):
                return self._json({"error": "Folder not found"}, 400)
            ALLOWED.add(os.path.realpath(root))
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            kws = _parse_kw(q)
            items = []
            try:
                for it in _scan_iter(root, kws):
                    items.append(it)
                    self.wfile.write((json.dumps({"item": it}) + "\n").encode())
                    self.wfile.flush()
                write_cache(root, items)
                self.wfile.write((json.dumps({"done": True, "root": root, "count": len(items)}) + "\n").encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:
                try:
                    self.wfile.write((json.dumps({"error": str(e)}) + "\n").encode())
                    self.wfile.flush()
                except Exception:
                    pass
            return
        if p == "/api/cached":
            root = (q.get("path") or [""])[0]
            if not root:
                return self._json({"miss": True})
            ALLOWED.add(os.path.realpath(root))   # allow streaming cached files without a rescan
            data = read_cache(root)
            if data is None:
                return self._json({"miss": True})
            return self._json({"root": root, "items": data.get("items", []), "cached": True})
        if p == "/api/peaks":
            t = (q.get("path") or [""])[0]
            if t and self._allowed(t) and os.path.isfile(t):
                return self._json(get_peaks(t))
            return self._json({"peaks": [], "rms": 0.0, "error": "forbidden"}, 403)
        if p == "/api/state":
            try:
                with open(STATE_FILE) as f:
                    return self._json(json.load(f))
            except Exception:
                return self._json({})
        if p == "/api/reveal":
            t = (q.get("path") or [""])[0]
            if t and self._allowed(t) and os.path.exists(t):
                subprocess.run(["open", "-R", t])
                return self._json({"ok": True})
            return self._json({"error": "forbidden"}, 403)
        if p == "/api/prefetch":
            t = (q.get("path") or [""])[0]
            if t and self._allowed(t) and os.path.isfile(t):
                with _pf_lock:
                    if t not in _pf_seen:
                        _pf_seen.add(t)
                        _pf_queue.put(t)
                return self._json({"ok": True})
            return self._json({"error": "forbidden"}, 403)
        if p == "/api/status":
            t = (q.get("path") or [""])[0]
            if t and self._allowed(t) and os.path.isfile(t):
                return self._json({"online": is_online_only(os.stat(t))})
            return self._json({"error": "forbidden"}, 403)
        if p == "/api/file":
            return self._file((q.get("path") or [""])[0])
        return self._static(p)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/api/state":
            try:
                ln = int(self.headers.get("Content-Length", "0") or "0")
                body = self.rfile.read(ln) if ln > 0 else b"{}"
                obj = json.loads(body.decode("utf-8") or "{}")
                if not isinstance(obj, dict):
                    raise ValueError("expected object")
                os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
                tmp = STATE_FILE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(obj, f)
                os.replace(tmp, STATE_FILE)   # atomic
                return self._json({"ok": True})
            except Exception as e:
                return self._json({"error": str(e)}, 400)
        return self._send(404, "text/plain", b"Not found")

    def _static(self, p):
        rel = p.lstrip("/") or "index.html"
        fp = os.path.normpath(os.path.join(ROOT, rel))
        if not fp.startswith(ROOT) or not os.path.isfile(fp):
            return self._send(404, "text/plain", b"Not found")
        ctype = mimetypes.guess_type(fp)[0] or "application/octet-stream"
        with open(fp, "rb") as f:
            self._send(200, ctype, f.read())

    def _file(self, path):
        if not path or not self._allowed(path) or not os.path.isfile(path):
            return self._send(403, "text/plain", b"forbidden")
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        try:
            if rng:
                m = re.match(r"bytes=(\d*)-(\d*)", rng)
                start = int(m.group(1)) if m and m.group(1) else 0
                end = int(m.group(2)) if m and m.group(2) else size - 1
                end = min(end, size - 1)
                start = min(start, end)
                length = end - start + 1
                self.send_response(206)
                self.send_header("Content-Type", ctype)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.send_header("Content-Length", str(length))
                self.end_headers()
                with open(path, "rb") as f:
                    f.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = f.read(min(65536, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            else:
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                with open(path, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
