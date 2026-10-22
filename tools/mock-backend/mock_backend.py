"""Mock Productify Gamezone session API for testing Productify Connect locally.

Implements the contract in DESIGN.md ("Backend API contract") with no GPU rental:

    POST /api/gamezone/sessions/{code}/connect   -> host, one-time PIN, app, network config
    POST /api/gamezone/sessions/{code}/pairing   -> submits the PIN to Sunshine (if configured)
    POST /api/gamezone/sessions/{code}/events    -> logs client events

Standard library only. Usage:

    py mock_backend.py                                   # codes below, host 127.0.0.1
    py mock_backend.py --host-address 192.168.1.50       # a Sunshine PC on your LAN
    py mock_backend.py --host-address 192.168.1.50 --sunshine-url https://192.168.1.50:47990 \
                       --sunshine-user admin             # password from SUNSHINE_PASS env var

Then run:  ProductifyConnect.exe join TEST-1234   (or open productify://connect?code=TEST-1234)
Built-in codes:
    TEST1234  direct connection to --host-address (works end to end with a real Sunshine)
    WGTEST12  WireGuard session with placeholder keys (exercises the tunnel path; will not connect)
    BOOTING1  409, machine still starting
    EXPIRED1  410, expired code
    anything else: 404
"""
import argparse
import base64
import json
import os
import re
import secrets
import ssl
import sys
import threading
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTE = re.compile(r"^/api/gamezone/sessions/([A-Za-z0-9]{6,16})/(connect|pairing|events)$")

ARGS = None
SESSIONS = {}          # code -> issued session (pin, pair_token, ...)
LOCK = threading.Lock()


def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def placeholder_key():
    return base64.b64encode(secrets.token_bytes(32)).decode()


def build_session(code, body):
    pin = f"{secrets.randbelow(10000):04d}"
    session = {
        "session_id": "mock-" + secrets.token_hex(6),
        "expires_at": (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat(timespec="seconds"),
        "host": {"name": "Productify Gamezone (mock)", "address": ARGS.host_address, "http_port": ARGS.http_port},
        "pairing": {"mode": "pin", "pin": pin, "pair_token": secrets.token_urlsafe(24)},
        "app": {"name": ARGS.app_name},
        "network": {"mode": "direct"},
    }
    if code == "TEST1234" and ARGS.wg_peer_key:
        # Real host behind WireGuard (e.g. a rented Vast VM): register the client's key on the host.
        client_key = body.get("wireguard_public_key") or ""
        if not re.fullmatch(r"[A-Za-z0-9+/]{43}=", client_key):
            raise ValueError("client did not send a valid wireguard_public_key")
        if ARGS.wg_peer_cmd:
            import subprocess
            r = subprocess.run(ARGS.wg_peer_cmd.replace("{key}", client_key), shell=True,
                               capture_output=True, text=True, timeout=30)
            log(f"  wg peer add -> rc={r.returncode} {r.stdout.strip()} {r.stderr.strip()[:200]}")
            if r.returncode != 0:
                raise ValueError("could not register the client's WireGuard key on the host")
        session["network"] = {
            "mode": "wireguard",
            "wireguard": {
                "interface_address": "10.77.0.2/32",
                "peer_public_key": ARGS.wg_peer_key,
                "endpoint": ARGS.wg_endpoint,
                "allowed_ips": "10.77.0.1/32",
                "host_tunnel_address": "10.77.0.1",
                "mtu": 1380,
                "persistent_keepalive": 25,
            },
        }
    if code == "WGTEST12":
        session["network"] = {
            "mode": "wireguard",
            "wireguard": {
                "interface_address": "10.77.0.2/32",
                "peer_public_key": placeholder_key(),
                "endpoint": f"{ARGS.host_address}:51820",
                "allowed_ips": "10.77.0.1/32",
                "host_tunnel_address": "10.77.0.1",
                "mtu": 1420,
                "persistent_keepalive": 25,
            },
        }
        if not body.get("wireguard_public_key"):
            raise ValueError("client did not send wireguard_public_key")
    return session


PIN_SUBMITTED = threading.Event()   # used by --fake-host to check the client's /pairing call


def submit_pin_to_sunshine(code, pin, device_name):
    """Sunshine accepts the PIN only while the client's pairing request is waiting, so retry briefly."""
    PIN_SUBMITTED.set()
    if ARGS.fake_host:
        log(f"{code}: (fake host) PIN submission received")
        return
    if ARGS.sunshine_ssh:
        # Production-like path: run curl on the VM itself; Sunshine credentials never leave the VM.
        import subprocess
        name = re.sub(r"[^A-Za-z0-9 _-]", "", device_name or "Productify Connect")[:40] or "Productify Connect"
        remote = ("set -a; . /root/gamezone-secrets; curl -sk -u \"$SUNSHINE_USER:$SUNSHINE_PASS\" "
                  "-H 'Content-Type: application/json' "
                  f"-d '{{\"pin\":\"{pin}\",\"name\":\"{name}\"}}' https://localhost:47990/api/pin")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            r = subprocess.run(ARGS.sunshine_ssh + " " + json.dumps(remote), shell=True,
                               capture_output=True, text=True, timeout=30)
            out = (r.stdout or "").strip()
            if '"status":true' in out.replace(" ", "") or '"status":"true"' in out.replace(" ", ""):
                log(f"{code}: Sunshine accepted the PIN (via ssh)")
                return
            log(f"{code}: Sunshine answered {out[:120]!r} rc={r.returncode}; retrying")
            time.sleep(1)
        log(f"{code}: gave up submitting the PIN")
        return
    if not ARGS.sunshine_url:
        log(f"{code}: no --sunshine-url; enter PIN {pin} in the Sunshine web UI within 30s to finish pairing")
        return
    password = os.environ.get("SUNSHINE_PASS", "")
    auth = base64.b64encode(f"{ARGS.sunshine_user}:{password}".encode()).decode()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False          # Sunshine uses a self-signed certificate
    ctx.verify_mode = ssl.CERT_NONE
    payload = json.dumps({"pin": pin, "name": device_name or "Productify Connect"}).encode()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        req = urllib.request.Request(ARGS.sunshine_url.rstrip("/") + "/api/pin", data=payload, method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": "Basic " + auth})
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
                result = json.loads(resp.read() or b"{}")
            if result.get("status") in (True, "true"):
                log(f"{code}: Sunshine accepted the PIN")
                return
            log(f"{code}: Sunshine not waiting for a PIN yet ({result}); retrying")
        except Exception as e:  # keep retrying through connection errors
            log(f"{code}: PIN submit failed ({type(e).__name__}: {e}); retrying")
        time.sleep(1)
    log(f"{code}: gave up submitting the PIN")


class Handler(BaseHTTPRequestHandler):
    server_version = "ProductifyMock/1.0"

    def log_message(self, fmt, *args):
        pass

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        self.reply(404, {"detail": "not found"})

    def do_POST(self):
        m = ROUTE.match(self.path)
        if not m:
            return self.reply(404, {"detail": "not found"})
        code, action = m.group(1).upper(), m.group(2)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except (ValueError, json.JSONDecodeError):
            return self.reply(400, {"detail": "invalid JSON"})

        log(f"POST {action} code={code} from {self.headers.get('User-Agent', '?')}")

        if action == "connect":
            if code == "BOOTING1":
                return self.reply(409, {"detail": "Your gaming machine is still starting. Try again in a minute.",
                                        "retry_after": 30})
            if code == "EXPIRED1":
                return self.reply(410, {"detail": "expired"})
            if code not in ("TEST1234", "WGTEST12"):
                return self.reply(404, {"detail": "unknown session code"})
            try:
                session = build_session(code, body)
            except ValueError as e:
                return self.reply(400, {"detail": str(e)})
            session["device_name"] = (body.get("client") or {}).get("device_name", "")
            with LOCK:
                SESSIONS[code] = session
            log(f"  issued session {session['session_id']} network={session['network']['mode']} "
                f"app={session['app']['name']!r} (PIN not logged)")
            return self.reply(200, {k: v for k, v in session.items() if k != "device_name"})

        with LOCK:
            session = SESSIONS.get(code)
        if not session or body.get("session_id") != session["session_id"]:
            return self.reply(404, {"detail": "unknown session"})

        if action == "pairing":
            if not secrets.compare_digest(str(body.get("pair_token", "")), session["pairing"]["pair_token"]):
                return self.reply(403, {"detail": "bad pair token"})
            threading.Thread(target=submit_pin_to_sunshine,
                             args=(code, session["pairing"]["pin"], session["device_name"]), daemon=True).start()
            return self.reply(202, {"status": "submitting"})

        log(f"  event {body.get('event')!r} {body.get('detail', '')}")
        return self.reply(202, {"status": "ok"})


FAKE_SERVERINFO = """<?xml version="1.0" encoding="utf-8"?>
<root status_code="200"><hostname>Productify Gamezone (fake)</hostname><appversion>7.1.431.-1</appversion>
<GfeVersion>3.23.0.74</GfeVersion><uniqueid>0123456789ABCDEF0123456789ABCDEF</uniqueid><HttpsPort>47984</HttpsPort>
<ExternalPort>47989</ExternalPort><mac>00:00:00:00:00:00</mac><MaxLumaPixelsHEVC>0</MaxLumaPixelsHEVC>
<LocalIP>127.0.0.1</LocalIP><ServerCodecModeSupport>1</ServerCodecModeSupport><PairStatus>0</PairStatus>
<currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state><gputype>fake</gputype></root>"""


class FakeHostHandler(BaseHTTPRequestHandler):
    """Just enough of Sunshine's HTTP (47989) API for the client to find the host and start pairing.

    It cannot complete pairing (no crypto); it checks that the client asked Productify to submit
    the PIN while its pairing request was waiting, then rejects the pairing."""

    def log_message(self, fmt, *args):
        pass

    def send_xml(self, xml):
        data = xml.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/serverinfo":
            return self.send_xml(FAKE_SERVERINFO)
        if path == "/pair":
            log("fake host: pairing request received, waiting for the PIN")
            PIN_SUBMITTED.clear()
            ok = PIN_SUBMITTED.wait(10)
            log(f"fake host: PIN {'was' if ok else 'was NOT'} submitted while pairing waited; rejecting (fake host)")
            return self.send_xml('<root status_code="200"><paired>0</paired></root>')
        if path == "/unpair":
            return self.send_xml('<root status_code="200"></root>')
        self.send_xml('<root status_code="404" status_message="not implemented"></root>')


def main(argv=None):
    global ARGS
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--host-address", default="127.0.0.1", help="Sunshine host address returned to the client")
    p.add_argument("--http-port", type=int, default=47989)
    p.add_argument("--app-name", default="Steam", help="must match the app's name in Sunshine's apps.json")
    p.add_argument("--sunshine-url", help="Sunshine web UI, e.g. https://192.168.1.50:47990")
    p.add_argument("--sunshine-user", default="admin")
    p.add_argument("--sunshine-ssh", help="ssh command prefix to the host (e.g. 'ssh -p 22 root@host'); the PIN is "
                                          "submitted by curl on the host using /root/gamezone-secrets")
    p.add_argument("--wg-peer-key", help="host WireGuard public key: TEST1234 then uses a tunnel")
    p.add_argument("--wg-endpoint", help="host WireGuard endpoint ip:port")
    p.add_argument("--wg-peer-cmd", help="shell command that registers {key} on the host, e.g. "
                                         "'ssh root@host gamezone-wg-peer add {key}'")
    p.add_argument("--fake-host", action="store_true",
                   help="also serve a fake Sunshine serverinfo/pair API on 127.0.0.1:47989 (no streaming)")
    ARGS = p.parse_args(argv)
    if ARGS.fake_host:
        ARGS.host_address = "127.0.0.1"
        fake = ThreadingHTTPServer(("127.0.0.1", 47989), FakeHostHandler)
        threading.Thread(target=fake.serve_forever, daemon=True).start()
        log("fake Sunshine host on http://127.0.0.1:47989")
    if ARGS.sunshine_url and not os.environ.get("SUNSHINE_PASS"):
        sys.exit("set SUNSHINE_PASS in the environment (it is never taken from the command line)")

    server = ThreadingHTTPServer((ARGS.bind, ARGS.port), Handler)
    log(f"mock Productify API on http://{ARGS.bind}:{ARGS.port} -> host {ARGS.host_address}, app {ARGS.app_name!r}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
