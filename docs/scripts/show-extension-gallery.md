# `show-extension-gallery.sh`

**Revision:** 1 · **Last modified:** 2026-07-01 · **Last verified:** 2026-07-01

Companion documentation (constitution §11.4.18) for
`scripts/show-extension-gallery.sh`. Run it from the repo root.

## Overview

Prints **which extension (plugin) marketplace gallery** HelixCode's code-server is
currently configured to use — a **read-only** probe, so you can confirm the
marketplace reality (`open-vsx.org`, not the Microsoft VS Code Marketplace)
without guessing (§11.4.6). It writes **nothing**, installs nothing, and **never**
switches the gallery — least of all to the Microsoft Marketplace, which is
licence-restricted to Microsoft products (see
[`docs/guides/EXTENSIONS.md`](../guides/EXTENSIONS.md) §1).

It reports three things, in precedence order:

1. **`EXTENSIONS_GALLERY` env var** — the highest-priority override (a VS Code
   `extensionsGallery` JSON blob). If set, its parsed `serviceUrl` / `itemUrl` are
   shown.
2. **`product.json` `extensionsGallery`** — the bundled VS Code `product.json`.
   On a stock code-server this is `null` (no gallery hard-coded there).
3. **Effective gallery** — what actually applies: the env override, else the
   `product.json` value, else code-server's **built-in default: Open VSX**
   (`serviceUrl https://open-vsx.org/vscode/gallery`,
   `itemUrl https://open-vsx.org/vscode/item`).

## Prerequisites

- `bash` **or** any POSIX `sh` — the script is parseable and runnable under both
  (§11.4.67; verified `bash -n` **and** `sh -n` clean).
- **No root**, no network, no writes.
- Optional: `jq` **or** `python3` to parse JSON (`serviceUrl` / `itemUrl`,
  `extensionsGallery`). Without either, the script degrades honestly — it prints
  an "install jq or python3" note rather than guessing.

## Usage

```bash
scripts/show-extension-gallery.sh                 # inspect this host's install
HELIX_CODE_SERVER_PRODUCT_JSON=/path/product.json \
  scripts/show-extension-gallery.sh               # point at a specific product.json
```

## Real output (this host, 2026-07-01)

```
HelixCode — configured extension (plugin) gallery
=================================================
(read-only probe; see docs/guides/EXTENSIONS.md)

[1] EXTENSIONS_GALLERY env var:
    not set

[2] product.json extensionsGallery:
    file: /home/milosvasic/.local/lib/code-server-4.117.0-linux-amd64/lib/vscode/product.json
    value: null  (no gallery hard-coded here)

[3] Effective gallery:
    -> code-server BUILT-IN DEFAULT: Open VSX (open-vsx.org)
         serviceUrl : https://open-vsx.org/vscode/gallery
         itemUrl    : https://open-vsx.org/vscode/item
```

## Configuration (never hard-coded — §11.4.6 / §11.4.28)

| Value | Source |
|---|---|
| `EXTENSIONS_GALLERY` | Read from the process environment (informational only — the script never sets it). |
| `product.json` path | `HELIX_CODE_SERVER_PRODUCT_JSON` if set; else the first match under `~/.local/lib/code-server-*/lib/vscode/`, `/usr/lib/code-server/…`, `/usr/local/lib/code-server/…`, `~/.local/share/code-server/…` (last match — highest version — wins). No version number is hard-coded. |
| Built-in default URLs | Open VSX (`https://open-vsx.org/vscode/gallery` / `…/item`) — public endpoints, printed as the documented fallback, not secrets. |

## Edge cases / internal behaviour

- **Read-only, always exit 0** on a clean run — it is an informational probe, not
  a gate. It does not fail the build.
- **product.json not found** → `[2]` reports that and suggests
  `HELIX_CODE_SERVER_PRODUCT_JSON`; `[3]` still reports the built-in Open VSX
  default (unless an env override is present).
- **No `jq`/`python3`** → JSON values print as `<unparsed>` / `<unknown — install
  jq or python3>`; the script never fabricates a value (§11.4.6).
- **`EXTENSIONS_GALLERY` set** → shown as the effective source; the parsed
  `serviceUrl`/`itemUrl` are printed (not the raw blob), so a URL that happened to
  carry a token is not echoed wholesale (§11.4.10-conscious).
- **Never mutates.** No file is written; the gallery is never changed. To *change*
  the gallery, follow [`EXTENSIONS.md`](../guides/EXTENSIONS.md) §3 (operator-gated,
  with the licensing caveat).

## Related

- [`docs/guides/EXTENSIONS.md`](../guides/EXTENSIONS.md) — the full operator guide
  to code-server's extension system and gallery configuration.
- `deploy/systemd/helix-code-server.service` — the unit whose `--extensions-dir` /
  `--user-data-dir` define HelixCode's private extension state.
- `tests/types/extensions_auth.sh` — the anti-bluff install + loadability suite
  (§11.4.169) that proves extensions really install from Open VSX and load.
