# HelixCode

**Revision:** 1 · **Last modified:** 2026-07-01T00:00:00Z

Containerized, network-exposed, browser-based **VS Code** (code-server) that
mounts your host projects for immediate work — behind a **Caddy** TLS edge,
running **rootless** (Podman), surviving reboot via a systemd service.

## Quick start (reproducible, reboot-persistent)

```bash
scripts/install.sh        # preflight → wizard (if needed) → start → boot service
```

Then open **`https://<host-ip>:52443`** and log in with the password you set.
`http://<host-ip>:52080` redirects to HTTPS.

Manual flow: `scripts/doctor.sh` → `scripts/setup.sh` → `scripts/start.sh` →
`scripts/status.sh`. Change the password anytime: `scripts/set-password.sh`.
Full script reference: [`docs/scripts/README.md`](docs/scripts/README.md).

## What you get

- **Caddy edge** on `0.0.0.0:52443` (HTTPS) / `:52080` (HTTP→HTTPS), reverse
  proxy to code-server. Ports derive from `PORT_PREFIX` in `deploy/.env`.
- **code-server** serving your host projects **read-write** (bind-mounted).
- **Rootless** containers (Podman, §11.4.161) — no root, no privilege escalation.
- **Boot-survival** rootless systemd user service (linger enabled).
- **Password change** without a rebuild (`set-password.sh`, atomic `.env` write).
- **File-watcher fix** — `files.watcherExclude` seeded into a persistent volume
  so large trees don't hit the inotify limit.

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

## Governance

Governed by the **Helix Constitution** (`constitution/`) — anti-bluff covenant,
rootless containers, no force-push, project-prefixed release tags. See
[`CLAUDE.md`](CLAUDE.md).
