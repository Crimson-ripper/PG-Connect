# PG Connect — notices

PG Connect is a modified version of **Moonlight PC** (moonlight-qt,
https://github.com/moonlight-stream/moonlight-qt), forked at release tag `v6.2.0`
(commit `de2467e433821664cdd2224aad8c89a625be1ad9`).

- Moonlight is Copyright (C) the Moonlight Game Streaming Project and its contributors.
- The Productify changes are Copyright (C) Productify.
- The whole program is distributed under the **GNU General Public License v3**; see `LICENSE`.
  You may redistribute and modify it under those terms. There is NO WARRANTY.
- "Moonlight" is a name used by the Moonlight Game Streaming Project. PG Connect is
  **not** endorsed by or affiliated with that project, and does not use its name or logo as
  its own branding.

## Corresponding source

The complete source code for every PG Connect binary is published at
`[TODO: public repository URL, e.g. https://github.com/<org>/productify-connect]`, tagged with
the same version as the binary. Productify's changes are listed in `PRODUCTIFY_CHANGES.md` and
are kept as separate commits on top of the upstream tag.

## Third-party components

Unchanged from upstream; each keeps its own licence:

| Component | Licence | Location |
|---|---|---|
| moonlight-common-c (incl. ENet, nanors, Reed-Solomon) | GPLv3 / MIT / BSD-style | `moonlight-common-c/` |
| qmdnsengine | MIT | `qmdnsengine/` |
| h264bitstream | LGPL 2.1 | `h264bitstream/` |
| SDL_GameControllerDB | zlib | `app/SDL_GameControllerDB/` |
| Prebuilt Windows libraries (FFmpeg, SDL2, Opus, OpenSSL, libplacebo, dav1d, Detours, discord-rpc) | see each project | downloaded by `setup-deps.ps1` from moonlight-stream/moonlight-qt-deps |
| Qt 6 | LGPL v3 (dynamically linked) | https://www.qt.io |

Optional, not bundled: WireGuard for Windows (https://www.wireguard.com), used only for
tunnelled sessions; "WireGuard" is a registered trademark of Jason A. Donenfeld.
