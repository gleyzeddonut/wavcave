"""HTTP-level tests for the WavCave backend (native/Server.swift).

The suite compiles the standalone server CLI once, boots it against a temp
library + data dir, and exercises every endpoint the UI uses: scanning with
keyword configs, the scan cache, durable state, waveform peaks, ranged audio
streaming, and the token/Host security checks.

Run with:  python3 -m pytest tests/ -v
"""
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
import array
import math
import shutil

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.join(os.path.dirname(HERE), "native")
TOKEN = "test-token-123"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def make_wav(path, seconds=1, rate=8000, freq=440):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    w = wave.open(path, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    a = array.array("h", (int(20000 * math.sin(2 * math.pi * freq * i / rate)) for i in range(rate * seconds)))
    w.writeframes(a.tobytes())
    w.close()


@pytest.fixture(scope="session")
def server_bin(tmp_path_factory):
    if not shutil.which("xcrun"):
        pytest.skip("xcrun/swiftc not available")
    out = tmp_path_factory.mktemp("build") / "wavcave-server"
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library",
         os.path.join(NATIVE, "Server.swift"), os.path.join(NATIVE, "server-cli.swift"),
         "-o", str(out)],
        check=True, capture_output=True, timeout=300,
    )
    return str(out)


@pytest.fixture(scope="session")
def library(tmp_path_factory):
    lib = tmp_path_factory.mktemp("library")
    make_wav(str(lib / "Kpop/ArtistA/Song1/Bounces/song one_140bpm.wav"))
    make_wav(str(lib / "Kpop/ArtistA/Song1/Bounces/song one_v2.wav"))
    make_wav(str(lib / "ArtistB/Song2/Mixdowns/song two inst.wav"))
    make_wav(str(lib / "NoMatch/deep/hidden.wav"))
    (lib / "Kpop/ArtistA/Song1/Bounces/notes.txt").write_text("not audio")
    return lib


class Server:
    def __init__(self, binary, root, data_dir, token):
        self.port = free_port()
        self.token = token
        env = dict(os.environ, BF_PORT=str(self.port), BF_ROOT=str(root),
                   BF_DATA_DIR=str(data_dir), BF_TOKEN=token)
        self.proc = subprocess.Popen([binary], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                self.get("/api/ping")
                return
            except Exception:
                if self.proc.poll() is not None:
                    raise RuntimeError("server died: %r" % self.proc.stdout.read())
                time.sleep(0.1)
        raise RuntimeError("server did not come up")

    def url(self, route, with_token=True, **params):
        if with_token and self.token:
            params.setdefault("t", self.token)
        qs = urllib.parse.urlencode(params)
        return "http://127.0.0.1:%d%s%s" % (self.port, route, ("?" + qs) if qs else "")

    def get(self, route, with_token=True, headers=None, **params):
        req = urllib.request.Request(self.url(route, with_token, **params), headers=headers or {})
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read()

    def get_json(self, route, **params):
        _, _, body = self.get(route, **params)
        return json.loads(body)

    def post_json(self, route, obj):
        req = urllib.request.Request(self.url(route), data=json.dumps(obj).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


@pytest.fixture(scope="session")
def srv(server_bin, library, tmp_path_factory):
    static = tmp_path_factory.mktemp("static")
    (static / "index.html").write_text("<html>wavcave test</html>")
    data = tmp_path_factory.mktemp("data")
    s = Server(server_bin, static, data, TOKEN)
    s.library = library
    s.data_dir = data
    yield s
    s.stop()


def scan(srv, path, kw=None):
    params = {"path": str(path)}
    if kw is not None:
        params["kw"] = json.dumps(kw)
    return srv.get_json("/api/scan", **params)


# ---------- basics ----------

def test_ping(srv):
    assert srv.get_json("/api/ping") == {"ok": True}


def test_pick_without_gui_cancels(srv):
    assert srv.get_json("/api/pick") == {"cancelled": True}


def test_static_index(srv):
    status, headers, body = srv.get("/")
    assert status == 200 and b"wavcave test" in body
    assert headers["Content-Type"].startswith("text/html")


def test_static_missing_is_404(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/nope.html")
    assert e.value.code == 404


def test_static_traversal_blocked(srv):
    # raw socket so urllib can't normalize the path for us
    s = socket.create_connection(("127.0.0.1", srv.port), timeout=5)
    s.sendall(b"GET /../secret.txt HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n" % srv.port)
    resp = s.recv(4096).decode()
    s.close()
    assert resp.startswith("HTTP/1.1 404")


# ---------- security ----------

def test_api_requires_token(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/ping", with_token=False)
    assert e.value.code == 401


def test_api_rejects_wrong_token(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/ping", with_token=False, t="wrong")
    assert e.value.code == 401


def test_foreign_host_header_rejected(srv):
    # a DNS-rebound page would arrive with its own hostname in Host
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/ping", headers={"Host": "evil.example.com"})
    assert e.value.code == 403


def test_localhost_host_header_ok(srv):
    status, _, _ = srv.get("/api/ping", headers={"Host": "localhost:%d" % srv.port})
    assert status == 200


def test_file_outside_allowed_roots_forbidden(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/file", path="/etc/hosts")
    assert e.value.code == 403


def test_token_written_to_data_dir(srv):
    tok_file = srv.data_dir / "token"
    assert tok_file.read_text().strip() == TOKEN
    assert (tok_file.stat().st_mode & 0o777) == 0o600


def test_no_token_mode(server_bin, library, tmp_path_factory):
    static = tmp_path_factory.mktemp("static2")
    data = tmp_path_factory.mktemp("data2")
    s = Server(server_bin, static, data, "")
    try:
        assert s.get_json("/api/ping") == {"ok": True}   # no token sent, none required
    finally:
        s.stop()


# ---------- scanning ----------

def test_scan_default_keyword(srv):
    j = scan(srv, srv.library)
    rels = sorted(i["rel"] for i in j["items"])
    assert rels == [
        "%s/Kpop/ArtistA/Song1/Bounces/song one_140bpm.wav" % srv.library.name,
        "%s/Kpop/ArtistA/Song1/Bounces/song one_v2.wav" % srv.library.name,
    ]
    item = j["items"][0]
    assert item["ext"] == "wav" and item["size"] > 0 and item["mtime"] > 0
    assert item["online"] is False
    assert os.path.isabs(item["abs"])


def test_scan_custom_keyword(srv):
    j = scan(srv, srv.library, kw=[{"word": "mixdown", "caseSensitive": False, "pluralize": True}])
    rels = [i["rel"] for i in j["items"]]
    assert rels == ["%s/ArtistB/Song2/Mixdowns/song two inst.wav" % srv.library.name]


def test_scan_case_sensitive_keyword(srv):
    j = scan(srv, srv.library, kw=[{"word": "bounces", "caseSensitive": True, "pluralize": False}])
    assert j["items"] == []   # folder on disk is "Bounces", capital B


def test_scan_multiple_keywords(srv):
    j = scan(srv, srv.library, kw=[
        {"word": "bounce", "caseSensitive": False, "pluralize": True},
        {"word": "mixdown", "caseSensitive": False, "pluralize": True},
    ])
    assert len(j["items"]) == 3


def test_scan_missing_folder_is_400(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/scan", path="/does/not/exist")
    assert e.value.code == 400


def test_scan_stream_ndjson(srv):
    status, headers, body = srv.get("/api/scan_stream", path=str(srv.library))
    assert status == 200 and headers["Content-Type"] == "application/x-ndjson"
    lines = [json.loads(l) for l in body.decode().strip().split("\n")]
    items = [l["item"] for l in lines if "item" in l]
    done = lines[-1]
    assert done["done"] is True and done["count"] == len(items) == 2


# ---------- scan cache ----------

def test_cached_after_scan(srv):
    scan(srv, srv.library)
    j = srv.get_json("/api/cached", path=str(srv.library))
    assert j.get("cached") is True and len(j["items"]) == 2


def test_cached_unknown_folder_misses(srv, tmp_path):
    j = srv.get_json("/api/cached", path=str(tmp_path))
    assert j == {"miss": True}


def test_cached_nonexistent_path_misses(srv):
    j = srv.get_json("/api/cached", path="/does/not/exist")
    assert j == {"miss": True}


# ---------- durable state ----------

def test_state_roundtrip(srv):
    payload = {"bf_favs": "[\"song one\"]", "bf_settings": "{\"sort\":\"artist\"}"}
    assert srv.post_json("/api/state", payload) == {"ok": True}
    assert srv.get_json("/api/state") == payload


def test_state_rejects_non_object(srv):
    req = urllib.request.Request(srv.url("/api/state"), data=b"[1,2,3]",
                                 headers={"Content-Type": "application/json"}, method="POST")
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(req, timeout=10)
    assert e.value.code == 400


# ---------- peaks ----------

def wav_path(srv):
    return str(srv.library / "Kpop/ArtistA/Song1/Bounces/song one_140bpm.wav")


def test_peaks(srv):
    scan(srv, srv.library)   # whitelists the folder
    j = srv.get_json("/api/peaks", path=wav_path(srv))
    peaks = j["peaks"]
    assert 0 < len(peaks) <= 800
    assert max(peaks) == 1.0            # normalized
    assert all(0 <= p <= 1 for p in peaks)
    assert "rms" not in j               # loudness matching was removed


def test_peaks_cached_on_disk(srv):
    srv.get_json("/api/peaks", path=wav_path(srv))
    cache_files = list((srv.data_dir / "peaks").glob("*.json"))
    assert cache_files
    c = json.loads(cache_files[0].read_text())
    assert c["size"] > 0 and c["peaks"]


def test_peaks_forbidden_outside_roots(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/peaks", path="/etc/hosts")
    assert e.value.code == 403


# ---------- file streaming ----------

def test_file_full(srv):
    scan(srv, srv.library)
    status, headers, body = srv.get("/api/file", path=wav_path(srv))
    assert status == 200
    assert headers["Accept-Ranges"] == "bytes"
    assert len(body) == os.path.getsize(wav_path(srv))
    assert body[:4] == b"RIFF"


def test_file_range(srv):
    status, headers, body = srv.get("/api/file", headers={"Range": "bytes=0-99"}, path=wav_path(srv))
    size = os.path.getsize(wav_path(srv))
    assert status == 206 and len(body) == 100
    assert headers["Content-Range"] == "bytes 0-99/%d" % size


def test_file_open_ended_range(srv):
    size = os.path.getsize(wav_path(srv))
    status, headers, body = srv.get("/api/file", headers={"Range": "bytes=100-"}, path=wav_path(srv))
    assert status == 206 and len(body) == size - 100
    assert headers["Content-Range"] == "bytes 100-%d/%d" % (size - 1, size)


def test_file_suffix_range(srv):
    size = os.path.getsize(wav_path(srv))
    status, headers, body = srv.get("/api/file", headers={"Range": "bytes=-100"}, path=wav_path(srv))
    assert status == 206 and len(body) == 100
    assert headers["Content-Range"] == "bytes %d-%d/%d" % (size - 100, size - 1, size)
    with open(wav_path(srv), "rb") as f:
        f.seek(size - 100)
        assert body == f.read()


# ---------- misc endpoints ----------

def test_status_endpoint(srv):
    scan(srv, srv.library)
    assert srv.get_json("/api/status", path=wav_path(srv)) == {"online": False}


def test_prefetch_endpoint(srv):
    assert srv.get_json("/api/prefetch", path=wav_path(srv)) == {"ok": True}


def test_reveal_forbidden_outside_roots(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/reveal", path="/etc/hosts")
    assert e.value.code == 403


# ---------- online-only (cloud placeholder) safety ----------
# A sparse file on APFS has st_blocks*512 < st_size, exactly like a Dropbox
# placeholder, so it exercises the same server paths without any cloud account.

def make_sparse(path, mb=64):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"RIFF\x00\x00\x00\x00WAVE")
        f.seek(mb * 1024 * 1024)
        f.write(b"\x00")


@pytest.fixture(scope="session")
def cloud_root(tmp_path_factory):
    root = tmp_path_factory.mktemp("cloudlib")
    make_sparse(str(root / "Bounces/huge cloud bounce.wav"))
    st = os.stat(root / "Bounces/huge cloud bounce.wav")
    if st.st_blocks * 512 >= st.st_size:
        pytest.skip("filesystem does not create sparse files")
    return root


def test_scan_marks_online_only(srv, cloud_root):
    j = scan(srv, cloud_root)
    assert len(j["items"]) == 1 and j["items"][0]["online"] is True


def test_status_reports_online_only(srv, cloud_root):
    scan(srv, cloud_root)
    p = str(cloud_root / "Bounces/huge cloud bounce.wav")
    assert srv.get_json("/api/status", path=p) == {"online": True}


def test_peaks_never_materialize_online_only_files(srv, cloud_root):
    # computing a waveform must NOT force a cloud download: no afconvert run,
    # empty peaks, and the client is told why
    scan(srv, cloud_root)
    p = str(cloud_root / "Bounces/huge cloud bounce.wav")
    j = srv.get_json("/api/peaks", path=p)
    assert j == {"peaks": [], "online": True}
    # and no peaks cache entry was written for it
    import hashlib
    h = hashlib.sha1(os.path.realpath(p).encode()).hexdigest()
    assert not (srv.data_dir / "peaks" / (h + ".json")).exists()


def test_prefetch_flood_stays_responsive(srv, cloud_root):
    # 30 rapid prefetch requests must be accepted instantly (bounded worker
    # pool drains them; the request itself never blocks on file reads)
    scan(srv, cloud_root)
    p = str(cloud_root / "Bounces/huge cloud bounce.wav")
    start = time.time()
    for _ in range(30):
        assert srv.get_json("/api/prefetch", path=p) == {"ok": True}
    assert srv.get_json("/api/ping") == {"ok": True}
    assert time.time() - start < 5


# ---------- free-space endpoint (Download all disk guard) ----------

def test_free_space_endpoint(srv):
    scan(srv, srv.library)
    j = srv.get_json("/api/free", path=str(srv.library))
    assert j["free"] > 0
    assert isinstance(j["dev"], int) and j["dev"] != 0


def test_free_space_forbidden_outside_roots(srv):
    with pytest.raises(urllib.error.HTTPError) as e:
        srv.get("/api/free", path="/etc")
    assert e.value.code == 403
