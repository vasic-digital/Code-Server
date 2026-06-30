#!/usr/bin/env bash
# scripts/logs.sh — tail HelixCode container logs.
#
# Purpose:      Show (and optionally follow) logs for the stack services.
# Usage:        scripts/logs.sh [code-server|caddy] [-f]
#               (no service → both; -f → follow)
# Inputs:       running containers
# Outputs:      container logs to stdout
# Side-effects: none
# Dependencies: bash; podman or docker
# Cross-references: docs/scripts/README.md, scripts/status.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
svc=""; follow=""
for a in "$@"; do
	case "$a" in
		-f|--follow) follow="-f" ;;
		code-server|caddy) svc="$a" ;;
		*) hc_warn "ignoring arg: $a" ;;
	esac
done
if [ -n "$svc" ]; then
	hc_compose logs $follow "$svc"
else
	hc_compose logs $follow
fi
