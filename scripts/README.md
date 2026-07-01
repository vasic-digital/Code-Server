# scripts/

HelixCode operator scripts. Full documentation:
[`docs/scripts/README.md`](../docs/scripts/README.md). Each script also has an
in-source doc block (Purpose / Usage / Inputs / Outputs / Side-effects /
Dependencies / Cross-references).

| Script | What it does |
|---|---|
| `install.sh` | **One-shot install** → preflight → configure → start → boot service |
| `setup.sh` | Setup wizard (CLI + `--tui`) → writes `deploy/.env` |
| `set-password.sh` | Change the login password + restart to apply |
| `tune-host.sh` | Raise host inotify limits (large trees; needs sudo) |
| `start.sh` | Start (build + up) the stack |
| `stop.sh` | Stop the stack (`--volumes` to drop volumes) |
| `restart.sh` | Stop then start |
| `status.sh` | Containers + exposed ports + TLS reachability |
| `logs.sh` | Tail logs (`[service] [-f]`) |
| `doctor.sh` | Preflight checks (runtime, config, ports, resources) |
| `install-service.sh` | Install systemd service (user default, `--system`) |
| `uninstall-service.sh` | Remove the systemd service |
| `lib.sh` | Shared helpers (sourced, not run directly) |

**Fresh host, reboot-persistent, one command:** `scripts/install.sh`
(runs the wizard if needed, starts the stack, installs the boot service).

Manual flow: `doctor.sh` → `setup.sh` → `start.sh` → `status.sh`.
Change password anytime: `set-password.sh`.
