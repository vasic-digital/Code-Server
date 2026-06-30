#!/usr/bin/env bash
# scripts/start.sh — start (or rebuild + start) the HelixCode stack.
#
# Purpose:      Bring the Caddy + code-server compose stack up in the background,
#               mounting the projects declared in deploy/.env ($PROJECTS).
# Usage:        scripts/start.sh
# Inputs:       deploy/.env (CODE_SERVER_PASSWORD, PROJECTS, PORT_PREFIX)
# Outputs:      running containers; prints the access URL
# Side-effects: pulls images on first run; generates deploy/compose.projects.yml
# Dependencies: bash; podman or docker; deploy/up.sh
# Cross-references: docs/scripts/README.md, scripts/setup.sh, scripts/status.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hc_require_env
hc_info "starting HelixCode stack…"
bash "$HC_DEPLOY/up.sh"
prefix="$(hc_prefix)"
hc_info "up. open: https://<host-ip>:${prefix}443  (http ${prefix}080 redirects)"
