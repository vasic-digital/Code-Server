# HelixCode

**Revision:** 3 · **Last modified:** 2026-07-01T19:06:08Z

Containerized, network-exposed, browser-based **VS Code** (code-server) that
mounts your host projects for immediate work — behind a **Caddy** TLS edge,
running **rootless** (Podman), surviving reboot via a systemd service.

> **Release `codeserver-1.0.0-dev-0.0.3` (2026-07-01).** Authentication pivots to
> the **real-account, SSH-key challenge-response** model — a session runs
> host-native as the real host user (`milosvasic`) with that user's `~/.ssh`,
> `.bashrc`, and host binaries, and login signs a fresh server-issued challenge
> against the account's `authorized_keys` (**no password, nothing stored**). The
> single `CODE_SERVER_PASSWORD` login is **retired**. New model + prerequisites +
> troubleshooting: [`docs/guides/AUTH.md`](docs/guides/AUTH.md); full change list:
> [`docs/changelogs/codeserver-1.0.0-dev-0.0.3.md`](docs/changelogs/codeserver-1.0.0-dev-0.0.3.md).
> **In progress — not yet validated** (§11.4.6); see
> [`docs/features/Status.md`](docs/features/Status.md).

## Quick start (reproducible, reboot-persistent)

```bash
scripts/install.sh        # preflight → wizard (if needed) → start → boot service
```

Then open **`https://<host-ip>:52443`** and log in with your **host account**
(`milosvasic`) SSH key — you sign a fresh challenge shown on the login page, no
password, nothing stored (see [Authentication](#authentication-real-account--ssh-key)
below). `http://<host-ip>:52080` redirects to HTTPS.

Manual flow: `scripts/doctor.sh` → `scripts/setup.sh` → `scripts/start.sh` →
`scripts/status.sh`.
Full script reference: [`docs/scripts/README.md`](docs/scripts/README.md).

## What you get

- **Caddy edge** on `0.0.0.0:52443` (HTTPS) / `:52080` (HTTP→HTTPS), reverse
  proxy to code-server. Ports derive from `PORT_PREFIX` in `deploy/.env`.
- **code-server** serving your host projects **read-write** (bind-mounted).
- **Real-account sessions** *(new, in progress)* — the editor runs host-native
  **as the real user**, so it natively has that user's SSH keys, `.bashrc`, and
  all host binaries; login is an **SSH-key challenge-response** verified against
  the account's `authorized_keys` — no password, nothing stored. See
  [Authentication](#authentication-real-account--ssh-key).
- **Rootless** containers (Podman, §11.4.161) — no root, no privilege escalation
  (Caddy TLS edge; the editor + auth run host-native).
- **Boot-survival** rootless systemd user service (linger enabled).
- **File-watcher fix** — `files.watcherExclude` seeded into a persistent volume
  so large trees don't hit the inotify limit.

## Authentication (real account + SSH-key)

> **New model, in progress — not yet validated.** This replaces the old single
> `CODE_SERVER_PASSWORD` login (and supersedes the earlier PAM-login draft —
> non-root PAM verify is impossible on this ALT/tcb host, so auth pivoted to SSH
> keys). The components are being built and their tests/evidence are still being
> produced; treat the behavior below as *intended*, not yet proven. Full guide:
> [`docs/guides/AUTH.md`](docs/guides/AUTH.md).

Each session is tied to a **real host user account** (default `milosvasic`). The
editor runs **host-native as that user**, so it natively inherits the user's
**SSH keys** (`~/.ssh` — git over SSH works from the integrated terminal), full
**`.bashrc`/profile**, and **all installed host binaries**. The login screen
shows a **fresh signed challenge**; you sign it locally with your SSH key —

```bash
printf %s '<challenge>' | ssh-keygen -Y sign -n helixcode-login -f ~/.ssh/id_ed25519
```

— and paste the signature back. A non-root `helix-auth` forward-auth gate behind
Caddy **verifies it against the account's `authorized_keys`** (`ssh-keygen -Y
verify`) and issues a signed session cookie. It **stores nothing** — no password
anywhere (repo, config, env, logs, evidence); your private key never leaves your
machine.

The editor's file **Explorer defaults to `$PROJECTS_ROOT`** for convenience — it
is **NOT a security boundary**: the integrated terminal, **File > Open Folder**,
and extensions retain **full real-user (`milosvasic`) access to the host
filesystem BY DESIGN**. Isolation, if ever required, would need a container / VM
/ chroot (out of scope per operator decision). Defense-in-depth (deploy stream,
in progress): code-server runs with `--disable-workspace-trust` and the
`/proxy/` path is blocked at the Caddy edge.

New parameters (replacing `CODE_SERVER_PASSWORD`, which is retired):

```ini
HELIX_AUTH_MODE=sshkey                        # only mode this release
HELIX_AUTH_ACCOUNT=milosvasic                 # the host account sessions tie to
HELIX_AUTH_AUTHORIZED_KEYS=~/.ssh/authorized_keys  # verifier's trust source
HELIX_AUTH_PRINCIPAL=milosvasic               # expected signer principal
PROJECTS_ROOT=                                # workspace + default Explorer folder (not a jail)
# No password parameter — login signs a server-issued challenge, verified against authorized_keys.
```

Security posture: auth **fails closed** (if the `helix-auth` gate is down, access
is denied — never bypassed), the challenge is **server-issued + short-lived**,
the session cookie is **HMAC-signed + HttpOnly + Secure + SameSite**, and login
is **rate-limited**. Details, prerequisites, and troubleshooting:
[`docs/guides/AUTH.md`](docs/guides/AUTH.md).

## HTTPS / TLS

Default is a per-boot **self-signed** cert (LAN-friendly). For real
**Let's Encrypt** with automatic renewal + rotation, set `TLS_MODE=letsencrypt`
(+ `CS_DOMAIN`, `ACME_EMAIL`) in `deploy/.env` — you need a public domain
resolving to the host with reachable `:80`/`:443`, **or** a DNS-01 token.
Modes, prerequisites, renewal/rotation behavior, and the local-CA proof:
[`docs/guides/TLS.md`](docs/guides/TLS.md).

## Testing (anti-bluff, §11.4.169)

```bash
bash tests/run_all_types.sh          # full test-type matrix (needs the stack)
bash tests/run_all_types.sh --list   # suites in risk-descending order
```

14 suites under `tests/types/` — unit, integration, e2e, full-automation,
security, load (DDoS), stress+chaos, concurrency, race, memory, benchmark,
Let's-Encrypt (local ACME CA), Challenges, HelixQA. Every PASS cites a captured
evidence file (`qa-results/`). Feature ledger:
[`docs/features/Status.md`](docs/features/Status.md).

## Tracked-Items + Status Documents

<!-- doc-link-section:begin -->
Always-in-sync tracked-item + status documents (§11.4.57), each shown with its
§11.4.44 **Revision** + **Last modified** (mirrored from the source header).
HelixCode's workable items live in the SQLite single-source-of-truth (§11.4.93);
this project ships no standalone `Issues`/`Fixed` Markdown trackers.

| Document | Last modified | Revision | Markdown | HTML | PDF |
|---|---|---|---|---|---|
| README | 2026-07-01T19:06:08Z | 3 | [.md](README.md) | [.html](README.html) | [.pdf](README.pdf) |
| CONTINUATION | 2026-07-01 | 5 | [.md](docs/CONTINUATION.md) | [.html](docs/CONTINUATION.html) | [.pdf](docs/CONTINUATION.pdf) |
| Feature Status | 2026-07-01T19:45:00Z | 2 | [.md](docs/features/Status.md) | [.html](docs/features/Status.html) | [.pdf](docs/features/Status.pdf) |
| Feature Status Summary | 2026-07-01T19:45:00Z | 1 | [.md](docs/features/Status_Summary.md) | [.html](docs/features/Status_Summary.html) | [.pdf](docs/features/Status_Summary.pdf) |
| Changelog `codeserver-1.0.0-dev-0.0.4` | 2026-07-01T00:00:00Z | 1 | [.md](docs/changelogs/codeserver-1.0.0-dev-0.0.4.md) | [.html](docs/changelogs/codeserver-1.0.0-dev-0.0.4.html) | [.pdf](docs/changelogs/codeserver-1.0.0-dev-0.0.4.pdf) |
| Extensions (plugins) guide | 2026-07-01T00:00:00Z | 1 | [.md](docs/guides/EXTENSIONS.md) | [.html](docs/guides/EXTENSIONS.html) | [.pdf](docs/guides/EXTENSIONS.pdf) |
| Caddy edge boot-persistence guide | 2026-07-01T19:10:00Z | 1 | [.md](docs/guides/EDGE_BOOT.md) | [.html](docs/guides/EDGE_BOOT.html) | [.pdf](docs/guides/EDGE_BOOT.pdf) |
| Auth-modernization research (deep-research) | 2026-07-01T18:26:19Z | 1 | [.md](docs/research/auth_modernization_20260701/FINDINGS.md) | [.html](docs/research/auth_modernization_20260701/FINDINGS.html) | [.pdf](docs/research/auth_modernization_20260701/FINDINGS.pdf) |
<!-- doc-link-section:end -->

## Governance

Governed by the **Helix Constitution** (`constitution/`) — anti-bluff covenant,
rootless containers, no force-push, project-prefixed release tags. See
[`CLAUDE.md`](CLAUDE.md).
