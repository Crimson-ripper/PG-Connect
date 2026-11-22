# Productify changes to moonlight-qt

Base: moonlight-qt `v6.2.0` (`de2467e`). Branch: `productify`. GPLv3 §5(a): this file and the
git history record what was modified and when. Design: `docs/DESIGN.md`.

## New files

- `app/productify/` — branding constants, session API client, join launcher, WireGuard tunnel,
  URL-handler registration, `productify.pri`
- `app/gui/JoinView.qml` — session-code start screen
- `app/productify.ico` — Productify icon
- `tools/mock-backend/` — mock session API + tests
- `tools/host/gamezone-wireguard-setup.sh` — host-side WireGuard reference
- `scripts/productify-build-dev.bat`, `.github/workflows/productify-windows.yml`
- `NOTICE.md`, `BUILDING-PRODUCTIFY.md`, `PRODUCTIFY_CHANGES.md`, `docs/DESIGN.md`

## Modified upstream files (2026-10-22)

| File | Change |
|---|---|
| `app/app.pro` | target names `PGConnect` / `pg-connect` / `PG Connect`; Windows version-info and icon; includes `productify/productify.pri` |
| `app/main.cpp` | organisation/app names; desktop file id; join view as start screen; `join`, deep-link and `register-url-handler` handling |
| `app/cli/commandlineparser.*` | `join`, `productify://` and `register-url-handler` actions |
| `app/qml.qrc` | adds `JoinView.qml` |
| `app/gui/main.qml`, `PcView.qml`, `SettingsView.qml`, `StreamSegue.qml` | user-visible "Moonlight" → "PG Connect"; help/update links → productifynow.com; Discord button hidden; `StreamSegue.qml`: `onEnded` callback so a quit stream returns to the launcher picker (2026-11-22, 0.1.8) |
| `app/backend/autoupdatechecker.cpp` | upstream update check disabled |
| `.github/workflows/` | upstream CI workflows removed; `productify-windows.yml` builds and releases PG Connect |
| `app/streaming/session.cpp`, `session.h` (2026-11-21) | `droppedMidStream()`: records whether a started stream ended because the network dropped, so the Productify join flow can reconnect |
| `app/gui/StreamSegue.qml` (2026-11-21) | optional `onDropped` callback: on a network drop it hands back to the join flow instead of showing the error and quitting |
| `app/version.txt` | PG Connect version (0.1.8) |
| `app/Moonlight.exe.manifest` | description |
| `wix/Moonlight/Product.wxs`, `wix/MoonlightSetup/Bundle.wxs` | product name, manufacturer, install folder, registry keys, new UpgradeCodes, icon, `productify://` handler |
| `scripts/build-arch.bat`, `scripts/generate-bundle.bat` | exe/zip/installer names; ships LICENSE and NOTICE.md |

Not yet rebranded (needed before macOS/Linux releases): `app/Info.plist`, `app/deploy/linux/*`,
`moonlight.svg/.icns`, AppImage/Flatpak/Steam Link scripts, translations.
