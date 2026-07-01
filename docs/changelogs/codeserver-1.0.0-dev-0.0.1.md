# codeserver-1.0.0-dev-0.0.1

**Revision:** 1 · **Last modified:** 2026-07-01T00:00:00Z

First tagged release of **HelixCode** — a containerized, network-exposed,
browser-based VS Code (code-server) that mounts the host projects for immediate
work. Dev pre-release: the core stack + operator tooling are functional and
validated; later phases (autonomous QA, VS Code profile sync, SQL/Docs-Chain
wiring) are still in progress, so this is intentionally not a final `1.0.0`.

## Highlights

### File-watcher fix — "unable to watch for file changes" (this round)
- **Root cause (captured):** code-server's parcel watcher exhausted the host
  inotify limit (`[File Watcher ('parcel')] Inotify limit reached (ENOSPC)`).
  inotify watches are counted per **directory**; the mounted tree has
  **678,457** directories vs a host limit of **499,678**.
- **Fix (two levers):**
  - *Reduce demand* — `deploy/code-server/settings.default.json` ships
    `files.watcherExclude` for VCS/build/dependency/backup dirs, seeded into a
    persistent `cs-data` volume on first boot (survives restart + reboot).
    Deterministic effect: **678,457 → 435,189** directories (**< 499,678**, fits).
  - *Increase supply* — `scripts/tune-host.sh` + `deploy/sysctl/99-helixcode-inotify.conf`
    raise `fs.inotify.max_user_watches` to 1,048,576 (host, needs root; optional
    headroom, auto-applied by `install.sh` when it has sudo).
- **Tests:** `tests/test_inotify_watchers.sh` — deterministic RED→GREEN polarity
  + paired §1.1 mutation (stripping a watcherExclude pattern makes it FAIL);
  wired into `tests/pre_build_verification.sh`.

### Operator tooling (recent rounds, included in this tag)
- One-shot `scripts/install.sh` (preflight → configure → host-tune → start →
  boot service); reproducible on any host.
- Boot-survival systemd **user** service (rootless; enabled + linger +
  `WantedBy=default.target`).
- `scripts/set-password.sh` — change the login password (verified at the auth
  layer: correct pw → HTTP 302 + argon2id session; wrong pw → HTTP 200).
- `scripts/{start,stop,restart,status,logs,doctor,setup,install-service,
  uninstall-service}.sh`, all documented (§11.4.18).

### Core stack
- Caddy edge on `0.0.0.0:52443` (HTTPS) / `:52080` (HTTP→HTTPS redirect),
  static self-signed cert with LAN-IP SANs regenerated per boot.
- code-server serving the host **Projects** read-write (35 projects), reachable
  on the LAN at `https://<host-ip>:52443`.

## Validation (anti-bluff, §11.4)
- TLS handshake `TLS_AES_128_GCM_SHA256`; login page served through Caddy
  (`HTTP 200`, `<title>code-server login</title>`).
- Projects read + write proven inside the container.
- Fix validated on a **clean deployment** (§11.4.108): first-boot seed, persists
  across container recreate and across the systemd-service boot path.
- Full pre-tag sweep: pre-build gate, constitution inheritance test, constitution
  meta-test mutation, inotify RED/GREEN + mutation — all green.

## Known / deferred
- Host inotify sysctl raise requires operator `sudo scripts/tune-host.sh`
  (this host had no passwordless sudo); `files.watcherExclude` already keeps the
  current tree under the limit without it.
- A literal host reboot was not performed (shared host with other projects'
  containers; no root); boot persistence is proven mechanically (service
  enabled + linger + `WantedBy=default.target`) and via the service boot path.
- Later phases pending: autonomous QA (HelixQA/Challenges), VS Code profile sync,
  SQL + Docs-Chain wiring.
