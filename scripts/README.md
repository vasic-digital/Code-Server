# scripts/

HelixCode operator scripts. Full documentation:
[`docs/scripts/README.md`](../docs/scripts/README.md). Each script also has an
in-source doc block (Purpose / Usage / Inputs / Outputs / Side-effects /
Dependencies / Cross-references).

| Script | What it does |
|---|---|
| `setup.sh` | Setup wizard (CLI + `--tui`) → writes `deploy/.env` |
| `start.sh` | Start (build + up) the stack |
| `stop.sh` | Stop the stack (`--volumes` to drop volumes) |
| `restart.sh` | Stop then start |
| `status.sh` | Containers + exposed ports + TLS reachability |
| `logs.sh` | Tail logs (`[service] [-f]`) |
| `doctor.sh` | Preflight checks (runtime, config, ports, resources) |
| `install-service.sh` | Install systemd service (user default, `--system`) |
| `uninstall-service.sh` | Remove the systemd service |
| `lib.sh` | Shared helpers (sourced, not run directly) |

Typical flow: `doctor.sh` → `setup.sh` → `start.sh` → `status.sh`.
