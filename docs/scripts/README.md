# HelixCode operator scripts

**Revision:** 3 · **Last modified:** 2026-07-01 · **Last verified:** 2026-07-01

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
