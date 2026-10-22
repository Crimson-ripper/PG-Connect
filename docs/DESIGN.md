# PG Connect — design

Status: **draft / pre-pilot** (2026-10-22). Nothing here is tested against a rented GPU yet.
Gamezone stays unadvertised on productifynow.com until the streaming tests in
`backend/gamezone/STREAMING_TEST_PLAN.md` pass (CLAUDE.md, honesty rules).

PG Connect is Productify's game-streaming client. It is a fork of **moonlight-qt**
(GPLv3) with one new feature: a player types a **Productify session code** (or clicks a
`productify://connect?code=…` link) and the client does everything else — finds the rented
machine, pairs with it automatically, optionally opens a WireGuard tunnel, and starts the one app
the session allows (Steam Big Picture or Epic via Heroic). No IP addresses, no PINs, no desktop.

```
 Player PC                                   Productify backend               Rented VM (Vast / E2E)
 ┌──────────────────────┐  1 POST connect    ┌──────────────────┐            ┌────────────────────────┐
 │ PG Connect   │ ─────────────────▶ │ session API      │  SSH/agent │ kiosk user (no desktop)│
 │  JoinView (code)     │ ◀───────────────── │  issues PIN,     │ ─────────▶ │ Sunshine (apps: Steam  │
 │  JoinLauncher        │  host, PIN, app,   │  WG peer, app    │  /api/pin  │   / Heroic only)       │
 │  SessionApi          │  network config    │                  │  wg peer   │ WireGuard wg0 (option) │
 │  WireGuardTunnel ────┼──────── 2 WireGuard (one identity-mapped UDP port) ─▶│                       │
 │  upstream Moonlight ─┼──────── 3 pair + stream (Sunshine std ports, in tunnel or direct) ─────────▶ │
 └──────────────────────┘  4 POST pairing ─▶ backend submits PIN to Sunshine                           │
```

---

## 1. Fork strategy

- **Upstream:** `moonlight-stream/moonlight-qt`, pinned at release tag **`v6.2.0`**
  (commit `de2467e`, 2026-10-03). The fork lives in `productify-connect/client` on branch
  **`productify`**, created from that tag.
- **Small patches on top of upstream.** Every Productify change is a separate commit on
  `productify`, listed in `client/PRODUCTIFY_CHANGES.md`. New code goes in new files
  (`app/productify/*`, `app/gui/JoinView.qml`, `tools/`, `.github/workflows/productify-*.yml`);
  edits to upstream files are kept to a few lines each (hooks in `main.cpp`, the CLI parser,
  `app.pro`, branding strings, WiX metadata).
- **Updating upstream:** `git fetch upstream --tags && git rebase --onto vX.Y.Z v6.2.0 productify`
  (or merge the new tag). Conflicts are expected only in `main.cpp`, `commandlineparser.*`,
  `app.pro`, `main.qml`, `Product.wxs`, `Bundle.wxs`, `build-arch.bat`. Check each release for
  security fixes; aim to rebase within two weeks of an upstream release.
- **Do not diverge the protocol.** Pairing, streaming and input stay upstream code so that
  Sunshine compatibility and bug fixes come for free. Things Productify might want to change
  there (e.g. per-session identities) go upstream as PRs where possible.
- **Clients for other platforms** follow the same pattern: macOS/Linux build from this same fork;
  Android forks `moonlight-android` (GPLv3) and reuses the same backend contract.

## 2. GPLv3 obligations (and the Moonlight name)

| Obligation | How we meet it |
|---|---|
| Publish corresponding source for every binary we distribute | Public repo of the `productify` branch; every release is a tag (`pfy-vX.Y.Z`) built by CI from that tag. NOTICE.md carries the source URL (`[TODO: confirm public repo URL]`). Source must stay available as long as we ship the binary. |
| Keep copyright / licence notices | `LICENSE` (GPLv3) untouched; upstream file headers untouched; `NOTICE.md` names Moonlight and its authors; both files ship inside the zip/MSI (`build-arch.bat`, dev script). |
| State that we modified it, and when | `NOTICE.md` + `PRODUCTIFY_CHANGES.md` + git history; Productify files carry a "modified version of Moonlight" header. |
| Licence our changes under GPLv3 | All of `app/productify/*`, `JoinView.qml`, tools: GPLv3 (same repo licence). The mock backend and host scripts are in the repo and also GPLv3. |
| No extra restrictions | No EULA that forbids reverse engineering/redistribution of the client. Backend terms of service can govern *use of Productify's service*, not the client's code. |
| Installation information | Not applicable (no locked-down "user product" hardware). Code signing is allowed; users can still build and run their own. |
| Third-party pieces | Qt is LGPLv3, dynamically linked (windeployqt) — fine. FFmpeg/SDL/OpenSSL etc. keep their licences (`NOTICE.md` table). |
| **Trademark** | "Moonlight" is the upstream project's name. The product name, window titles, installer, Start-menu entry, exe name and icon are all Productify's. We only say "based on Moonlight" for attribution. Moonlight's logo is not used for our branding (upstream `moonlight.svg/.ico/.icns` remain in the tree only for not-yet-rebranded macOS/Linux bits — replace before shipping those). |

Not legal advice: have someone review NOTICE.md and the store listings before the first public release.

## 3. What was added (architecture)

| Piece | File(s) | What it does |
|---|---|---|
| Branding | `app/productify/branding.h`, `app.pro`, `main.cpp`, QML strings, `productify.ico`, WiX | App/org name "PG Connect"/"Productify" (settings and pairings are separate from any Moonlight install), exe `PGConnect.exe`, new MSI/bundle UpgradeCodes, upstream update checker and Discord link disabled. |
| Join screen | `app/gui/JoinView.qml` | Default start screen: one code field, Join button, progress text, errors. Upstream's host list (`PcView`) only appears with `PRODUCTIFY_CLASSIC_UI=1` (developers). |
| Deep link / CLI | `cli/commandlineparser.*`, `main.cpp`, `urlhandler.*`, `Product.wxs` | `PGConnect.exe join <code>`, `PGConnect.exe productify://connect?code=…`, `register-url-handler` (portable builds, HKCU). The MSI registers `productify://` in HKCR. A link can only carry the code — never a server address. |
| Session API client | `app/productify/sessionapi.*` | Calls the backend (§4); validates the response (exactly one app, sane PIN, WG fields, no `/0` routes). HTTPS required except for a backend on localhost. API base: build-time `PFY_API_BASE` (CI repository variable) or env `PRODUCTIFY_API_BASE`; dev default `http://127.0.0.1:8765` (mock). |
| Join flow | `app/productify/joinlauncher.*` | State machine: fetch session → (tunnel up) → `ComputerSeeker` finds Sunshine → if not paired, `ComputerManager::pairHost(pin)` and 1.5 s later `POST …/pairing` so the backend submits the PIN to Sunshine → reuse upstream `CliStartStream::Launcher` to start the session's only app → `StreamSegue` with `quitAfter`. Sends `stream_started` / `stream_ended` / `client_error` events. |
| WireGuard | `app/productify/wgtunnel.*` | Per-session X25519 key generated on the device (OpenSSL); only the public key goes to the backend. Phase 1 (Windows): writes a split-tunnel config and runs the installed WireGuard for Windows `wireguard.exe /installtunnelservice` (UAC prompt), removes it with `/uninstalltunnelservice` at exit and deletes the config (it holds the private key). |
| Mock backend | `tools/mock-backend/mock_backend.py` (+ tests) | Local stand-in for §4 with fixed test codes; can forward the PIN to a real Sunshine on your LAN. |
| Host script (reference) | `tools/host/gamezone-wireguard-setup.sh` | wg0 on the identity UDP port, Sunshine ports only reachable via wg0/loopback, `gamezone-wg-peer add|remove-all` for the backend. To be merged into the kiosk onstart script after test T-K2. |
| CI | `.github/workflows/productify-windows.yml` | Windows x64 build with upstream's toolchain (portable zip + MSI + PDBs) and mock-backend tests. |

### Player-only-sees-the-game guarantees

The client is not a security boundary (it is open source; anyone can build a client that asks for
another app). The guarantees are on the host and backend:

1. Sunshine's `apps.json` lists only Steam Big Picture / Heroic — no "Desktop" entry (kiosk onstart).
2. The kiosk X session has no panel, terminal or file manager; Openbox has no menus/keybindings.
3. The client only ever requests `app.name` from the session; it never shows the host's app grid.
4. Sunshine's web UI (47990) stays bound to the machine (`origin_web_ui_allowed = pc`); its
   credentials never leave the backend.
5. Remaining gap to test (STREAMING_TEST_PLAN X-tests): escaping Big Picture via Steam's built-in
   browser / desktop mode, Heroic's "open folder", Alt+Tab, Ctrl+Alt+F-keys. Steam's desktop mode
   should be disabled in the kiosk.

## 4. Backend API contract (v1)

All under the existing FastAPI app, namespace `/api/gamezone/sessions/{code}` (kept out of
`/api/games/{game_id}` so it cannot collide with the catalogue routes). Codes: 6–16 chars
`[A-Z0-9]`, displayed with dashes (`PFY-7K2M-9QXD`); the client strips spaces/dashes and upper-cases.

**Code rules (backend):** created when the player's rental is ready; single player; TTL ≈ 10 min
for the first `connect`, then bound to the first client (reconnects within the rental accepted
from the same WG key / device); rate-limit by IP and by code (e.g. 10/min); never log PINs or keys.

### `POST /connect`

Request:
```json
{
  "client": {"name": "PG Connect", "version": "6.2.0", "platform": "windows-x86_64", "device_name": "LENOVO-PC"},
  "supports": {"wireguard": true},
  "wireguard_public_key": "base64 X25519 public key (only when supports.wireguard)"
}
```
Response `200`:
```json
{
  "session_id": "gz_01J…",
  "expires_at": "2026-10-22T14:00:00+00:00",
  "host": {"name": "Productify Gamezone", "address": "203.0.113.10", "http_port": 47989},
  "pairing": {"mode": "pin", "pin": "4821", "pair_token": "opaque, single use"},
  "app": {"name": "Steam"},
  "network": {"mode": "direct"}
}
```
or with a tunnel:
```json
  "network": {"mode": "wireguard", "wireguard": {
     "interface_address": "10.77.0.2/32", "peer_public_key": "host key", "preshared_key": "optional",
     "endpoint": "203.0.113.10:41641", "allowed_ips": "10.77.0.1/32",
     "host_tunnel_address": "10.77.0.1", "mtu": 1420, "persistent_keepalive": 25}}
```
- `app.name` must equal the name in Sunshine's `apps.json` (`"Steam"` or `"Epic Games (Heroic)"` today).
- `pairing.mode` is `"already_paired"` when the backend knows this client is paired (reconnect).
- Backend side effects: generate a random 4-digit PIN (single use, valid ~2 min); for WireGuard,
  `ssh root@vm gamezone-wg-peer add <client key>` and read the host key/port from
  `/root/gamezone-secrets`; for Vast, **resolve the real identity port** from the instance's port
  map (the template's `741641` is above 65535, so it is a Vast placeholder for "identity-mapped",
  not a port — confirmed 2026-10-22: it appeared as `"54879/udp": [{"HostPort": "54879"}]`).

Errors (`{"detail": "…"}`): `404` unknown code · `410` expired/used · `409` machine not ready
(`retry_after` seconds) · `429` rate limited · `400` bad request (e.g. tunnel needed but no key).

### `POST /pairing`
Request `{"session_id": "…", "pair_token": "…"}` → `202`. The client sends this ~1.5 s after it
starts Moonlight pairing (Sunshine only accepts a PIN while a pairing request is waiting). The
backend then calls Sunshine **from the VM side** — `POST https://localhost:47990/api/pin`
`{"pin": "4821", "name": "<device_name>"}` with the per-session Sunshine admin credentials
(`/root/gamezone-secrets`), over SSH or the host agent — retrying for ~20 s until
`{"status": true}`. `403` bad token, `404` unknown session, `410` PIN expired.

### `POST /events`
Request `{"session_id": "…", "event": "stream_started|stream_ended|client_error", "detail": "…"}`
→ `202`. Informational only — **billing must use server-side timestamps** (rental start/stop),
not client events.

### Session end (backend, no client call)
At rental end: `gamezone-wg-peer remove-all`, Sunshine `POST /api/clients/unpair-all`, rotate
Sunshine credentials, destroy or wipe the VM before re-use.

### Alternative: pre-shared pairing (phase 2)
Instead of a PIN round-trip, the backend could generate the client certificate, inject it into
Sunshine's paired-clients state before the player connects, and return the cert/key in `connect`.
Moonlight keeps one identity per install, so this needs a client change (import identity per
host). Not worth it until the PIN flow is measured as a problem.

## 5. WireGuard plan

**Why:** Vast maps container/VM ports randomly and Moonlight needs Sunshine's fixed ports
(TCP 47984/47989/48010, UDP 47998–48000/48002/48010). moonlight-common-c takes only the *port*
from Sunshine's RTSP URL and always connects to the address it was given, so if that address is
inside a tunnel everything uses standard ports inside it. One identity-mapped UDP port carries
WireGuard. E2E Networks VMs with a public IP can use `network.mode = "direct"`.

**Rules:** split tunnel only (`AllowedIPs` = host /32; the client refuses `/0`), no DNS, key pair
per session generated on the device, one peer per VM, peers removed at session end, Sunshine
ports firewalled to wg0 on the host.

| Phase | Windows mechanism | Player experience | Status |
|---|---|---|---|
| **1 (now)** | Installed WireGuard for Windows; one elevated `cmd` step copies the config to `%ProgramData%\Productify\tunnels` (SYSTEM/Admins only) and runs `wireguard.exe /installtunnelservice` | Needs WireGuard installed; one UAC prompt to connect and one at exit | Implemented; **worked against a real Vast VM on 2026-10-22** |
| **2** | Ship `tunnel.dll` + `wireguard.dll` (wireguard-windows *embeddable-dll-service* / wireguard-nt) and a small **PG Connect Tunnel** Windows service installed by the MSI (LocalSystem). The app talks to it over a named pipe with an ACL for interactive users; the service only accepts configs that are split-tunnel to `10.77.0.0/16`. | No extra install, no UAC per session | Design only |
| **2b (alt)** | Userspace WireGuard + userspace TCP/IP (wireguard-go + gVisor netstack, as in *wireproxy*) forwarding `127.0.0.1:{Sunshine ports}` into the tunnel | No admin rights at all; cross-platform (also macOS/Linux/Android) | Design only; needs latency/throughput test (video is ~20–50 Mbit/s UDP) and handling of local port clashes |
| macOS / Linux | Network Extension (macOS) / `wg-quick` via pkexec or 2b (Linux) | — | Not started (client says "not supported on this platform") |
| Android | `GoBackend` from wireguard-android inside the moonlight-android fork (VpnService) | One VPN consent prompt | Not started |

Recommendation: ship phase 1 only to internal testers; do 2b first if its latency cost is under
~1 ms on the T4 test (keeps everything unprivileged and portable), else 2.

## 6. Build and toolchain (Windows)

Verified locally on 2026-10-22 (Windows 10 22H2):

| Tool | Version |
|---|---|
| Visual Studio 2022 Build Tools, "Desktop development with C++" | MSVC 14.44.35207 |
| Qt | **6.12.0** `win64_msvc2022_64` (same as upstream v6.2.0 CI), installed with aqtinstall at upstream's pinned commit `073e34d` |
| jom | from download.qt.io/official_releases/jom (optional; nmake works) |
| Prebuilt deps | `setup-deps.ps1` → moonlight-qt-deps release **v19** (FFmpeg, SDL2/3, OpenSSL 3, Opus, libplacebo, dav1d, Detours) |
| Release packaging only | 7-Zip (`7z` on PATH), WiX v4 via `msbuild -Restore` (NuGet), present on GitHub `windows-2025` runners |

Steps: see `client/BUILDING-PRODUCTIFY.md`. CI: `client/.github/workflows/productify-windows.yml`.

## 7. Phased plan

| Phase | Scope | Exit criteria |
|---|---|---|
| **0 — done here** | Fork at v6.2.0, rebrand, session-code flow, mock backend, WG phase-1 code, Windows build + CI | Client builds; join flow passes against the mock (§8) |
| **1 — Windows pilot (internal)** | Implement §4 in `backend/server.py` + `backend/gamezone/`; WG host script into the kiosk onstart; publish the source repo; code-signing cert; test T-K2 on one Vast VM and one E2E VM (needs paid rentals — ask first) | A tester goes from code to Steam Big Picture with no manual steps; 1080p60, input works; X-tests (escape attempts) pass |
| **2 — tunnel without friction** | WG phase 2 or 2b; reconnect after network drop; Productify update feed; crash reporting opt-in | No UAC/WireGuard install needed; updates delivered |
| **3 — macOS + Linux** | Rebrand Info.plist/.desktop/AppImage/Flatpak id `com.productifynow.PGConnect`, icons, `productify://` handlers, tunnel per §5 | Same join flow on both |
| **4 — Android** | Fork moonlight-android, same contract, VpnService tunnel, Play listing | Same join flow on Android |

## 8. Testing

- `py -I tools/mock-backend/test_mock_backend.py` — contract tests of the mock (run in CI).
- Manual (no GPU needed): start the mock, run `PGConnect.exe join TEST-1234` →
  error "did not answer" after the seek timeout (no Sunshine at 127.0.0.1) proves the code →
  API → seek path; `BOOTING1`/`EXPIRED1`/`NOPE0000` show the 409/410/404 messages; `WGTEST12`
  exercises the tunnel path (UAC prompt / "install WireGuard" message).
- Full local E2E without renting: any PC on the LAN with Sunshine and an app named `Steam` →
  `mock_backend.py --host-address <ip> --sunshine-url https://<ip>:47990` (SUNSHINE_PASS in env).
- Real host: STREAMING_TEST_PLAN T-K, T-K2, X-tests — **rents machines; ask the user first.**
- `mock_backend.py --fake-host` also serves a fake Sunshine HTTP API on 127.0.0.1:47989 (serverinfo + pair
  stage 1), which checks that the client asks Productify to submit the PIN *while* its pairing request
  is waiting.

**Results on 2026-10-22 (local, Windows 10, release dev build):**

| Case | Result |
|---|---|
| `join TEST-1234` + `--fake-host` | connect → host found → pairing started → `/pairing` received while Sunshine "waited" → fake host rejects → "Pairing failed" shown, `client_error` event sent ✅ |
| `BOOTING1` / `NOPE-0000` / deep link `productify://connect?code=EXPIRED1` | 409 / 404 / 410 messages shown ✅ |
| `WGTEST12` (WireGuard not installed here) | "This session needs WireGuard…" ✅ (tunnel bring-up itself not exercised) |
| invalid code `ab` | join screen opens empty, no request ✅ |
| Join screen look | not visually checked by the agent (log shows no QML errors) |

**Real Vast VM test, 2026-10-22 (T-K2) — PASS (functional).** RTX 3060 VM in Quebec (Xeon E5-2680 v2,
$0.14/h, ~1.25 h), Vast's official Ubuntu Desktop (VM) template, client on the player's Windows 10 PC in
India, mock backend in real-host mode. Code → WireGuard tunnel on the identity UDP port → host found →
**automatic pairing with the one-time PIN** → Steam launched → 1080p60 H.264 stream → **mouse and
keyboard confirmed working by the player** → `stream_ended` + tunnel removed on exit. Reconnect skipped
pairing. Ping through the tunnel 380–611 ms and some frame loss: distance, not a quality result.
Report: `test_reports/20261022-vast-vm-TK2-productify-connect.json`.

Fixed during the test:
- Client: WireGuard's SYSTEM service could not open configs in the user's AppData → configs now go to
  `%ProgramData%\Productify\tunnels` (ACL: SYSTEM + Administrators) inside the same elevated step.
- Client: a single host request right after the tunnel came up was lost during the WireGuard handshake →
  probe Sunshine's port every second (≤ 45 s) before handing over to Moonlight's host search.
- Client: delete stale staging configs left by a killed client.
- Host script: `apt-get update` first; stop the image's `tailscaled`, which already listens on the identity port.
- Kiosk onstart (web repo, **not changed here**): Sunshine's PATH lacks `/usr/games`, so app commands
  must use `/usr/games/steam`.

Vast findings: `-p 741641:741641/udp` became **54879/udp ↔ 54879** (identity, number chosen by Vast;
read it from the instance's `ports`). VM creation needs an account-level SSH key and works with
`template_hash_id` of the official VM template. For real gaming hosts, filter on CPU model too, not only
GPU (old Xeons like the E5-2680 v2 are too slow for modern games).
