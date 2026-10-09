"""A local stand-in for the Spotify Web API and accounts service, for driving
the plugin in a real Tern window without a Spotify account.

    python tests/mock_spotify.py [PORT]

Start Tern with
    TERN_SPOTIFY_API=http://127.0.0.1:PORT/v1
    TERN_SPOTIFY_ACCOUNTS=http://127.0.0.1:PORT
and sign in with any 32-hex Client ID. /authorize answers with a redirect to
the callback carrying code TESTCODE.

Test hooks:
    GET  /_log            every request so far (JSON)
    POST /_expire         the current access token answers 401 from now on
    POST /_rate?n=1       the next n API requests answer 429 (Retry-After: 2)
    POST /_premium?on=0   playback commands answer 403 PREMIUM_REQUIRED
    POST /_nodevice       nothing plays; no device is active
"""

import base64
import hashlib
import json
import struct
import sys
import threading
import time
import urllib.parse
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 47900
BASE = f"http://127.0.0.1:{PORT}"

LOCK = threading.Lock()
LOG: list = []


def png(w: int, h: int, rgb: tuple) -> bytes:
    raw = b"".join(b"\0" + bytes(rgb) * w for _ in range(h))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


ART = {"a1": png(300, 300, (29, 185, 84)), "a2": png(300, 300, (180, 60, 160))}


def track(n: int, album: str = "a1") -> dict:
    return {
        "type": "track",
        "uri": f"spotify:track:t{n}",
        "id": f"t{n}",
        "name": f"Track number {n}",
        "duration_ms": 180000 + n * 1000,
        "explicit": n % 4 == 0,
        "artists": [{"name": "The Mockers"}, {"name": "Guest"}] if n % 3 == 0 else [{"name": "The Mockers"}],
        "album": {
            "name": "Mock Album" if album == "a1" else "Second Album",
            "uri": f"spotify:album:{album}",
            "images": [
                {"url": f"{BASE}/art/{album}.png", "width": 300, "height": 300},
                {"url": f"{BASE}/art/{album}.png?s=64", "width": 64, "height": 64},
            ],
        },
    }


DEVICES = [
    {"id": "dev1", "name": "Desk Speaker", "type": "Speaker", "is_active": True, "is_restricted": False, "volume_percent": 40, "supports_volume": True},
    {"id": "dev2", "name": "Phone", "type": "Smartphone", "is_active": False, "is_restricted": False, "volume_percent": 70, "supports_volume": True},
    {"id": None, "name": "Locked TV", "type": "TV", "is_active": False, "is_restricted": True, "volume_percent": None, "supports_volume": False},
]

STATE = {
    "tokens": {},  # access token -> valid
    "refresh": "R-0",
    "seq": 0,
    "rate": 0,
    "premium": True,
    "playing": True,
    "index": 1,
    "started": time.time(),
    "offset_ms": 42000,
    "shuffle": False,
    "repeat": "off",
    "device": "dev1",
    "active": True,
    "queue": [],
    "liked": set(),
    "context": "spotify:album:a1",
    "added": [],
}


def position_ms() -> int:
    if STATE["playing"]:
        return int(STATE["offset_ms"] + (time.time() - STATE["started"]) * 1000)
    return int(STATE["offset_ms"])


def set_position(ms: int) -> None:
    STATE["offset_ms"], STATE["started"] = ms, time.time()


def new_tokens(rotate: bool = True) -> dict:
    STATE["seq"] += 1
    access = f"A-{STATE['seq']}"
    STATE["tokens"][access] = True
    if rotate:
        STATE["refresh"] = f"R-{STATE['seq']}"
    out = {"access_token": access, "token_type": "Bearer", "expires_in": 3600, "scope": "user-read-playback-state user-modify-playback-state user-library-read user-library-modify playlist-read-private playlist-modify-public playlist-modify-private"}
    if rotate:
        out["refresh_token"] = STATE["refresh"]
    return out


def player() -> dict | None:
    if not STATE["active"]:
        return None
    t = track(STATE["index"], "a1" if STATE["index"] % 2 else "a2")
    pos = position_ms()
    if pos >= t["duration_ms"]:
        STATE["index"] += 1
        set_position(0)
        t = track(STATE["index"], "a1" if STATE["index"] % 2 else "a2")
        pos = 0
    dev = next(d for d in DEVICES if d["id"] == STATE["device"])
    return {
        "device": {**dev, "is_active": True},
        "shuffle_state": STATE["shuffle"],
        "repeat_state": STATE["repeat"],
        "timestamp": int(time.time() * 1000),
        "context": {"uri": STATE["context"], "type": STATE["context"].split(":")[1]},
        "progress_ms": pos,
        "item": t,
        "currently_playing_type": "track",
        "is_playing": STATE["playing"],
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    def send(self, status: int, body=None, headers: dict | None = None, raw: bytes | None = None, ctype="application/json"):
        data = raw if raw is not None else (b"" if body is None else json.dumps(body).encode())
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if data:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def api_error(self, status: int, message: str, reason: str | None = None):
        err = {"status": status, "message": message}
        if reason:
            err["reason"] = reason
        self.send(status, {"error": err})

    def handle_any(self, method: str):
        parsed = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(parsed.query))
        length = int(self.headers.get("Content-Length") or 0)
        body_raw = self.rfile.read(length) if length else b""
        path = parsed.path
        with LOCK:
            LOG.append({"method": method, "path": path, "query": query, "body": body_raw.decode(errors="replace"), "auth": self.headers.get("Authorization")})
            self.route(method, path, query, body_raw)

    def route(self, method, path, query, body_raw):
        # test hooks
        if path == "/_log":
            return self.send(200, LOG)
        if path == "/_expire":
            STATE["tokens"] = {k: False for k in STATE["tokens"]}
            return self.send(204)
        if path == "/_rate":
            STATE["rate"] = int(query.get("n", "1"))
            return self.send(204)
        if path == "/_premium":
            STATE["premium"] = query.get("on", "1") == "1"
            return self.send(204)
        if path == "/_nodevice":
            STATE["active"] = False
            return self.send(204)
        if path.startswith("/art/"):
            key = path[len("/art/"):].removesuffix(".png")
            return self.send(200, raw=ART.get(key, ART["a1"]), ctype="image/png")

        # accounts
        if path == "/authorize":
            target = "http://127.0.0.1:8888/callback?" + urllib.parse.urlencode({"code": "TESTCODE", "state": query.get("state", "")})
            return self.send(302, headers={"Location": target})
        if path == "/api/token" and method == "POST":
            form = dict(urllib.parse.parse_qsl(body_raw.decode()))
            if form.get("grant_type") == "authorization_code":
                if form.get("code") != "TESTCODE" or not form.get("code_verifier"):
                    return self.send(400, {"error": "invalid_grant", "error_description": "Invalid authorization code"})
                return self.send(200, new_tokens())
            if form.get("grant_type") == "refresh_token":
                if form.get("refresh_token") != STATE["refresh"]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "Refresh token revoked"})
                return self.send(200, new_tokens(rotate=STATE["seq"] % 2 == 0))
            return self.send(400, {"error": "unsupported_grant_type"})

        if not path.startswith("/v1/"):
            return self.send(404, {"error": "not found"})
        token = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
        if not STATE["tokens"].get(token):
            return self.api_error(401, "The access token expired")
        if STATE["rate"] > 0:
            STATE["rate"] -= 1
            return self.send(429, None, {"Retry-After": "2"})
        api = path[len("/v1"):]
        return self.web_api(method, api, query, body_raw)

    def web_api(self, method, api, query, body_raw):
        body = json.loads(body_raw) if body_raw else {}
        command = method != "GET" and api.startswith("/me/player")
        if command and not STATE["premium"]:
            return self.api_error(403, "Player command failed: Premium required", "PREMIUM_REQUIRED")
        if command and not STATE["active"] and api not in ("/me/player",):
            return self.api_error(404, "Player command failed: No active device found", "NO_ACTIVE_DEVICE")

        if method == "GET" and api == "/me/player":
            p = player()
            return self.send(200, p) if p else self.send(204)
        if method == "PUT" and api == "/me/player/pause":
            set_position(position_ms())
            STATE["playing"] = False
            return self.send(204)
        if method == "PUT" and api == "/me/player/play":
            if body.get("uris"):
                STATE["index"] = int(body["uris"][0].rsplit("t", 1)[-1])
                set_position(0)
            elif body.get("context_uri"):
                STATE["context"] = body["context_uri"]
                off = body.get("offset") or {}
                if "uri" in off:
                    STATE["index"] = int(off["uri"].rsplit("t", 1)[-1])
                elif "position" in off:
                    STATE["index"] = 200 + int(off["position"])
                set_position(0)
            else:
                set_position(position_ms())
            STATE["playing"] = True
            STATE["started"] = time.time()
            return self.send(204)
        if method == "POST" and api in ("/me/player/next", "/me/player/previous"):
            STATE["index"] += 1 if api.endswith("next") else -1
            STATE["index"] = max(STATE["index"], 1)
            set_position(0)
            return self.send(204)
        if method == "PUT" and api == "/me/player/seek":
            set_position(int(query["position_ms"]))
            return self.send(204)
        if method == "PUT" and api == "/me/player/volume":
            next(d for d in DEVICES if d["id"] == STATE["device"])["volume_percent"] = int(query["volume_percent"])
            return self.send(204)
        if method == "PUT" and api == "/me/player/shuffle":
            STATE["shuffle"] = query["state"] == "true"
            return self.send(204)
        if method == "PUT" and api == "/me/player/repeat":
            STATE["repeat"] = query["state"]
            return self.send(204)
        if method == "PUT" and api == "/me/player":
            STATE["device"] = body["device_ids"][0]
            STATE["active"] = True
            STATE["playing"] = bool(body.get("play"))
            for d in DEVICES:
                d["is_active"] = d["id"] == STATE["device"]
            return self.send(204)
        if method == "POST" and api == "/me/player/queue":
            STATE["queue"].append(query["uri"])
            return self.send(204)
        if method == "GET" and api == "/me/player/queue":
            p = player()
            q = [track(int(u.rsplit("t", 1)[-1])) for u in STATE["queue"]] + [track(STATE["index"] + i) for i in range(1, 6)]
            return self.send(200, {"currently_playing": p and p["item"], "queue": q})
        if method == "GET" and api == "/me/player/devices":
            return self.send(200, {"devices": DEVICES})
        if method == "GET" and api == "/me/playlists":
            offset = int(query.get("offset", "0"))
            items = [
                {"uri": f"spotify:playlist:p{i}", "id": f"p{i}", "name": f"Playlist {i}", "owner": {"id": "mock-user" if i % 2 == 0 else "someone-else", "display_name": "mock-user" if i % 2 == 0 else "someone-else"}, "items": {"total": 10 + i}, "images": []}
                for i in range(offset, min(offset + 50, 60))
            ]
            nxt = f"{BASE}/v1/me/playlists?offset={offset + 50}&limit=50" if offset + 50 < 60 else None
            return self.send(200, {"items": items + [None] if offset == 0 else items, "next": nxt, "total": 60})
        if method == "GET" and api.startswith("/playlists/") and api.endswith("/items"):
            # February 2026 contract: entries under `item`, limit <= 50, and only for
            # playlists the user owns or collaborates on (odd ids here are followed ones).
            if int(query.get("limit", "20")) > 50:
                return self.api_error(400, "Invalid limit")
            pid = api.split("/")[2]
            if int(pid.lstrip("p") or 0) % 2 == 1:
                return self.api_error(403, "Forbidden")
            return self.send(200, {"items": [{"item": track(200 + i)} for i in range(12)] + [{"item": None}], "next": None, "total": 13})
        if method == "GET" and api == "/me":
            return self.send(200, {"id": "mock-user", "display_name": "Mock User"})
        if api == "/me/library/contains" and method == "GET":
            uris = query.get("uris", "").split(",")
            return self.send(200, [u in STATE["liked"] for u in uris])
        if api == "/me/library" and method in ("PUT", "DELETE"):
            for u in query.get("uris", "").split(","):
                (STATE["liked"].add if method == "PUT" else STATE["liked"].discard)(u)
            return self.send(200)
        if method == "POST" and api.startswith("/playlists/") and api.endswith("/items"):
            pid = api.split("/")[2]
            if int(pid.lstrip("p") or 0) % 2 == 1:
                return self.api_error(403, "Forbidden")
            STATE["added"].append((pid, body.get("uris")))
            return self.send(201, {"snapshot_id": "s"})
        if method == "GET" and api == "/me/tracks":
            return self.send(200, {"items": [{"added_at": "x", "track": track(300 + i)} for i in range(20)], "next": None, "total": 20})
        if method == "GET" and api == "/search":
            q = query.get("q", "")
            return self.send(200, {
                "tracks": {"items": [{**track(400 + i), "name": f"{q} song {i}"} for i in range(3)]},
                "albums": {"items": [{"uri": "spotify:album:a2", "name": f"{q} album", "artists": [{"name": "The Mockers"}], "images": []}]},
                "artists": {"items": [{"uri": "spotify:artist:x", "name": f"{q} artist", "images": []}]},
                "playlists": {"items": [None, {"uri": "spotify:playlist:s", "id": "s", "name": f"{q} mix", "owner": {"display_name": "Spotify"}, "items": {"total": 50}, "images": []}]},
            })
        return self.api_error(404, f"No mock for {method} {api}")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")


if __name__ == "__main__":
    print(f"mock spotify on {BASE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
