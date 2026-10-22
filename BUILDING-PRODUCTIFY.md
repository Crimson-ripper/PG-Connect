# Building Productify Connect (Windows x64)

Tested 2026-10-22 on Windows 10 22H2 with the toolchain below. CI does the same in
`.github/workflows/productify-windows.yml`.

## Toolchain

| Tool | Version | Notes |
|---|---|---|
| Visual Studio 2022 (Build Tools is enough) | MSVC 14.44 | workload "Desktop development with C++" |
| Qt | 6.12.0, `win64_msvc2022_64` | same version upstream moonlight-qt v6.2.0 uses |
| Python 3 | 3.10+ | only for installing Qt with aqtinstall, and the mock backend |
| jom (optional) | any | https://download.qt.io/official_releases/jom/jom.zip — faster than nmake |
| 7-Zip + WiX (release packaging only) | — | `scripts\build-arch.bat` needs `7z` on PATH; WiX v4 is restored by msbuild |

## Steps

```bat
git clone --recurse-submodules -b productify <this repo> client
cd client
powershell -ExecutionPolicy Bypass -File setup-deps.ps1

rem Qt (once). aqtinstall at the commit upstream pins; 3.3.0 from PyPI cannot list 6.12 archs.
py -m venv ..\.toolchain\venv
..\.toolchain\venv\Scripts\pip install "git+https://github.com/miurahr/aqtinstall.git@073e34d7c2ab4ae6961ed7cca690b3abd5ba5a7e"
..\.toolchain\venv\Scripts\aqt install-qt windows desktop 6.12.0 win64_msvc2022_64 --outputdir ..\.toolchain\Qt

rem Development build -> build\dev-deploy-x64-release\ProductifyConnect.exe (portable)
scripts\productify-build-dev.bat release

rem Release build (portable zip + MSI), from a shell with Qt's bin on PATH and 7z available:
set PFY_API_BASE=https://<production api host>
scripts\build-arch.bat release
```

Without `PFY_API_BASE` the client talks to the local mock backend at `http://127.0.0.1:8765`
(`tools/mock-backend/mock_backend.py`). At run time `PRODUCTIFY_API_BASE` overrides it
(HTTPS required unless the host is localhost).

## Trying the join flow

```bat
py -I tools\mock-backend\mock_backend.py
build\dev-deploy-x64-release\ProductifyConnect.exe join TEST-1234
```

Test codes: `TEST1234` (direct), `WGTEST12` (WireGuard path), `BOOTING1` (409), `EXPIRED1` (410),
anything else 404. Set `PRODUCTIFY_CLASSIC_UI=1` to get upstream's host list instead of the join
screen.

Notes:
- Upstream's `scripts\build-arch.bat` calls `vswhere -latest` without `-products *`, so it does
  not find a Build-Tools-only install; `productify-build-dev.bat` passes `-products *`.
- `register-url-handler` writes `HKCU\Software\Classes\productify` for portable builds; the MSI
  registers the handler itself.
