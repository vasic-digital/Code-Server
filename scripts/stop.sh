#!/usr/bin/env bash
# scripts/stop.sh — stop the HelixCode stack (containers down).
#
# Purpose:      Tear down the running Caddy + code-server compose stack.
# Usage:        scripts/stop.sh [--volumes]   # --volumes also removes named volumes
# Inputs:       deploy/compose.codeserver.yml (+ generated projects override)
# Outputs:      stopped/removed containers
# Side-effects: removes the compose containers (+ volumes with --volumes); host
#               project files are NEVER touched (they are bind mounts).
# Dependencies: bash; podman or docker
# Cross-references: docs/scripts/README.md, scripts/start.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
extra=()
[ "${1:-}" = "--volumes" ] && extra=(--volumes)
hc_info "stopping HelixCode stack…"
hc_compose down "${extra[@]}" || hc_warn "nothing to stop (already down?)"
hc_info "stopped."
