# HelixCode operator scripts

**Revision:** 4 · **Last modified:** 2026-07-01 · **Last verified:** 2026-07-01

Companion documentation (constitution §11.4.18) for every script under
`scripts/`. Each script also carries an in-source documentation block. Run any
script from the repo root, e.g. `scripts/start.sh`.

## Quick start

**One command (recommended — reproducible on any host, survives reboot):**

```bash
scripts/install.sh       # preflight → wizard (if needed) → start → boot service
```

Or step by step:

```bash
scripts/doctor.sh        # preflight checks
scripts/setup.sh         # wizard → writes deploy/.env
scripts/start.sh         # bring the stack up
scripts/status.sh        # verify it's reachable
# … work in the browser at https://<host>:52443 …
scripts/set-password.sh  # change the login password (any time)
scripts/stop.sh          # bring it down
```

---

## `install.sh`
- **Overview:** One-shot installer that makes a deployment reproducible on any
  host and reboot-persistent: runs `doctor.sh`, launches `setup.sh` if
  `deploy/.env` is missing, starts the stack, then installs the boot-survival
  systemd service (user service by default; `--system` for a root unit;
  `--no-service` to skip). This is the canonical install path.
- **Prerequisites:** bash; podman or docker; systemd.
- **Usage:** `scripts/install.sh` · `scripts/install.sh --system` ·
  `scripts/install.sh --no-service`
- **Edge cases:** on re-install `doctor.sh` may warn that ports are in use
  (the running stack) — advisory, install continues.
- **Related:** `setup.sh`, `start.sh`, `install-service.sh`, `set-password.sh`.

## `set-password.sh`
- **Overview:** Changes the code-server login password: rewrites
  `CODE_SERVER_PASSWORD` in `deploy/.env` (keeping the port prefix + projects,
  mode 600) and restarts the stack so it takes effect immediately.
- **Prerequisites:** `deploy/.env` present (run `setup.sh`/`install.sh` first).
- **Usage:** `scripts/set-password.sh` (interactive, recommended) ·
  `NEW_PASSWORD=… scripts/set-password.sh` · `scripts/set-password.sh --password …`
- **Edge cases:** `--password` puts the secret in the process list — prefer the
  interactive prompt or `NEW_PASSWORD` env. If the stack is stopped, the new
  password applies on the next `start.sh`.
- **Related:** `setup.sh`, `restart.sh`, `install.sh`.

## `tune-host.sh`
- **Overview:** Raises host inotify limits so code-server can watch large
  workspaces without the "unable to watch for file changes" (ENOSPC) warning.
  Installs `deploy/sysctl/99-helixcode-inotify.conf` into `/etc/sysctl.d/` and
  applies it. inotify limits are a host-kernel, per-UID resource (not
  per-container), so this must run on the host as root.
- **Prerequisites:** root (sudo) to install/apply; runs read-only with `--show`.
- **Usage:** `sudo scripts/tune-host.sh` · `scripts/tune-host.sh --show`
- **Edge cases:** without root it prints the exact `cp` + `sysctl --system`
  commands and exits non-zero. `install.sh` runs it automatically when it has
  root/sudo. code-server also ships `files.watcherExclude` defaults (seeded into
  the `cs-data` volume by `deploy/up.sh`), so raising the sysctl is **optional
  headroom** — the excludes already keep a typical large tree under the limit.
- **Related:** `install.sh`, `deploy/sysctl/`, `deploy/code-server/settings.default.json`.

### The file-watcher fix (background)
Large project trees can exceed the kernel's `fs.inotify.max_user_watches`
(watches are counted per **directory**). HelixCode addresses this two ways:
1. **Reduce demand** — `deploy/code-server/settings.default.json` sets
   `files.watcherExclude` for VCS/build/dependency/backup dirs. It is seeded
   into the persistent `cs-data` volume on first boot and survives restarts +
   reboots. Edit it in the code-server UI (Settings) to tune further.
2. **Increase supply** — `scripts/tune-host.sh` raises the host inotify limits
   (needs root; optional but recommended for very large trees).
Regression guard: `tests/test_inotify_watchers.sh`.

---

## `lib.sh`
- **Overview:** Shared helper library sourced by the other scripts (repo-root
  resolution, runtime detection, `.env` loading, a compose wrapper, logging).
- **Prerequisites:** bash. Not executed directly — it is sourced.
- **Usage:** `. scripts/lib.sh`
- **Internal behaviour:** exports `HC_ROOT`, `HC_DEPLOY`; provides `hc_runtime`,
  `hc_compose`, `hc_load_env`, `hc_prefix`, `hc_require_env`, `hc_info/warn/err`.
- **Related:** all other scripts.

## `setup.sh`
- **Overview:** Interactive setup wizard (CLI by default, whiptail TUI with
  `--tui`). Collects port prefix, projects, and login password; writes
  `deploy/.env` (mode 600, never committed).
- **Prerequisites:** bash; optional `whiptail` for the TUI.
- **Usage:** `scripts/setup.sh` · `scripts/setup.sh --tui` ·
  `CODE_SERVER_PASSWORD=… PROJECTS=… scripts/setup.sh --non-interactive`
- **Edge cases:** rejects a port prefix where `PREFIX*1000+999 > 65535`; requires
  a non-empty, confirmed password; falls back to CLI if whiptail is absent.
- **Related:** `deploy/.env.example`, `start.sh`.

## `start.sh`
- **Overview:** Brings the Caddy + code-server stack up (builds on first run),
  mounting `$PROJECTS` from `deploy/.env`. Prints the access URL.
- **Prerequisites:** `deploy/.env` (run `setup.sh` first); podman or docker.
- **Usage:** `scripts/start.sh`
- **Edge cases:** exits with guidance if `deploy/.env` is missing; first run
  pulls images.
- **Related:** `deploy/up.sh`, `stop.sh`, `status.sh`.

## `stop.sh`
- **Overview:** Tears the stack down. `--volumes` also removes named volumes.
  Host project files are never touched (they are bind mounts).
- **Usage:** `scripts/stop.sh` · `scripts/stop.sh --volumes`
- **Related:** `start.sh`.

## `restart.sh`
- **Overview:** `stop.sh` then `start.sh` — use after editing `deploy/.env`.
- **Usage:** `scripts/restart.sh`
- **Related:** `start.sh`, `stop.sh`.

## `status.sh`
- **Overview:** Reports container status, exposed-port listeners (`ss`), and a
  TLS reachability probe (`openssl`). Exit 0 only if HTTPS answers.
- **Prerequisites:** podman/docker; `ss`; `openssl` (optional).
- **Usage:** `scripts/status.sh`
- **Related:** `start.sh`, `logs.sh`.

## `logs.sh`
- **Overview:** Tails container logs. Optional service filter + `-f` to follow.
- **Usage:** `scripts/logs.sh` · `scripts/logs.sh caddy -f` ·
  `scripts/logs.sh code-server`
- **Related:** `status.sh`.

## `doctor.sh`
- **Overview:** Preflight checklist (runtime present, `.env` valid, ports free,
  disk/memory). Exit 0 only if no FAIL.
- **Usage:** `scripts/doctor.sh`
- **Related:** `setup.sh`.

## `install-service.sh`
- **Overview:** Installs a systemd unit so the stack starts on boot. Rootless
  **user** service by default (enables linger); `--system` for a root unit.
- **Prerequisites:** systemd; `deploy/.env`.
- **Usage:** `scripts/install-service.sh` · `scripts/install-service.sh --system`
- **Edge cases:** warns if linger can't be enabled (service may stop on logout).
- **Related:** `uninstall-service.sh`, `start.sh`, `stop.sh`.

## `uninstall-service.sh`
- **Overview:** Stops, disables, and removes the systemd unit.
- **Usage:** `scripts/uninstall-service.sh` · `scripts/uninstall-service.sh --system`
- **Related:** `install-service.sh`.

## `install-auth.sh`
- **Overview:** Wires up the host-native real-account editor with SSH-key
  challenge-response login. Installs **code-server** from the pinned
  `CODE_SERVER_VERSION`'s **standalone GitHub-release tarball** (PRIMARY):
  downloads `code-server-<ver>-linux-amd64.tar.gz`, extracts it to the
  user-writable prefix `~/.local/lib/code-server-<ver>-linux-amd64`, and symlinks
  its `bin/code-server` into `~/.local/bin/code-server` (on PATH). The tarball is
  the robust path on this host — it avoids the npm registry version lag
  (4.118–4.126 are GitHub-only, so `npm i -g` E404s) and the
  corrupted-tarball/ENOENT npm failures. **npm global** (`npm i -g
  code-server@<ver>`) remains the documented fallback if the tarball fetch fails.
  Then builds the `helix-auth` gate (when `services/auth_gate/` is present) and
  installs/enables the `helix-code-server` + `helix-auth` systemd `--user` units.
  Everything runs NON-root (no sudo, no `/etc/pam.d`).
- **Prerequisites:** bash; `curl` or `wget` + `tar` (tarball install); `~/.local/bin`
  on PATH; systemd `--user`; `go` (only if building the gate); `npm` (only for the
  fallback).
- **Usage:** `scripts/install-auth.sh` · `scripts/install-auth.sh -h` ·
  `CODE_SERVER_VERSION=4.117.0 scripts/install-auth.sh`
- **Internal behaviour:** idempotent — the early `command -v code-server` check
  skips the install when code-server is already present, and the tarball step
  re-uses an already-extracted pinned version; success is proven by running the
  extracted `code-server --version` and asserting it equals the pin (§11.4.6). The
  release publishes no per-version checksum, so checksum verification is
  best-effort (verified when a checksum file is present). `HC_INSTALL_AUTH_SELFTEST=<dir>`
  exercises ONLY the tarball fetch+extract+verify into a sandbox dir and exits —
  a non-destructive proof seam that never touches `~/.local`, systemd, or the live
  install.
- **Edge cases:** if `~/.local/bin` is not on PATH the script warns after a
  successful install; if both the tarball and npm paths fail it exits non-zero with
  guidance. Never touches any process/unit not named `helix-code-server` /
  `helix-auth` (§11.4.174).
- **Related:** `deploy/systemd/*.service`, `deploy/up.sh`, `deploy/.env.example`,
  `docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md`.

## `harden-loopback.sh`
- **Overview:** Closes the `--auth none` residual risk of the host-native editor:
  code-server listens on `127.0.0.1:8080` with no per-UID access control, so any
  local UID can reach it and get a shell as the account, bypassing the Caddy gate.
  Installs a UID-scoped loopback OUTPUT firewall rule (nftables preferred, iptables
  fallback) that DROPs connections to `127.0.0.1:<port>` from any UID other than the
  account (rootless Caddy connects AS the account, so it stays allowed).
  Defence-in-depth, NOT a replacement for the fail-closed Caddy gate. Reads the
  account + port from `deploy/.env` — nothing hard-coded (§11.4.6/§11.4.28).
- **Prerequisites:** `--check` needs no root (read-only). `--apply`/`--remove` need
  **root** + `nft` or `iptables`; the script never escalates — it refuses politely
  with the exact root re-run command.
- **Usage:** `scripts/harden-loopback.sh --check` ·
  `su - -c '… scripts/harden-loopback.sh --apply'` ·
  `scripts/harden-loopback.sh --remove` · `scripts/harden-loopback.sh --help`
- **Edge cases:** idempotent; `--check` exits `0` only when the rule is confirmed
  present, `1` when absent or unverifiable (fail-closed reporting). nft/iptables
  rules are runtime state — persist them after `--apply` to survive reboot.
- **Related:** `deploy/systemd/helix-code-server.service` (RESIDUAL RISK block),
  `docs/scripts/harden-loopback.md`, `docs/guides/AUTH.md` §5.1, `install-auth.sh`.
