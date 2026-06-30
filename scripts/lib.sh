#!/usr/bin/env bash
# scripts/lib.sh — shared helpers for the HelixCode operator scripts.
#
# Purpose:      Common functions (repo-root resolution, container-runtime
#               detection, .env loading, compose wrapper, coloured logging)
#               sourced by the other scripts in this directory.
# Usage:        source "$(dirname "$0")/lib.sh"   # not executed directly
# Inputs:       deploy/.env (optional, loaded by hc_load_env)
# Outputs:      exports HC_ROOT, HC_DEPLOY; provides hc_* helper functions
# Side-effects: none (pure helpers)
# Dependencies: bash; podman or docker (for hc_runtime/hc_compose)
# Cross-references: docs/scripts/README.md, deploy/up.sh, deploy/README.md
set -euo pipefail

HC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HC_DEPLOY="$HC_ROOT/deploy"

hc_info() { printf '\033[1;34m[helixcode]\033[0m %s\n' "$*"; }
hc_warn() { printf '\033[1;33m[helixcode]\033[0m %s\n' "$*" >&2; }
hc_err()  { printf '\033[1;31m[helixcode]\033[0m %s\n' "$*" >&2; }

# hc_runtime — echo the compose driver ("podman compose" | "docker compose").
hc_runtime() {
	if command -v podman >/dev/null 2>&1; then echo "podman compose"
	elif command -v docker >/dev/null 2>&1; then echo "docker compose"
	else hc_err "neither podman nor docker found on PATH"; return 1; fi
}

# hc_compose ARGS… — run compose in deploy/ with the base file (+ the generated
# projects override if present). Example: hc_compose ps / hc_compose down.
hc_compose() {
	local rt files
	rt="$(hc_runtime)" || return 1
	files=( -f compose.codeserver.yml )
	[ -f "$HC_DEPLOY/compose.projects.yml" ] && files+=( -f compose.projects.yml )
	( cd "$HC_DEPLOY" && $rt "${files[@]}" "$@" )
}

# hc_load_env — source deploy/.env into the environment (no error if missing).
hc_load_env() {
	if [ -f "$HC_DEPLOY/.env" ]; then set -a; . "$HC_DEPLOY/.env"; set +a; fi
}

# hc_prefix — echo the configured port prefix (default 52).
hc_prefix() { hc_load_env 2>/dev/null || true; echo "${PORT_PREFIX:-52}"; }

# hc_require_env — fail with guidance if deploy/.env is absent.
hc_require_env() {
	[ -f "$HC_DEPLOY/.env" ] || { hc_err "deploy/.env not found — run: scripts/setup.sh"; return 1; }
}
