#!/usr/bin/env bash
# scripts/status.sh — show HelixCode stack status + reachability.
#
# Purpose:      Report container status, exposed-port listeners, and a TLS
#               reachability probe so an operator sees what is actually up.
# Usage:        scripts/status.sh
# Inputs:       deploy/.env (PORT_PREFIX); running containers
# Outputs:      human-readable status to stdout; exit 0 if the HTTPS port answers
# Side-effects: none (read-only probes)
# Dependencies: bash; podman or docker; ss (iproute2); openssl (optional)
# Cross-references: docs/scripts/README.md, scripts/start.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
prefix="$(hc_prefix)"; https="${prefix}443"; http="${prefix}080"

echo "== containers =="
hc_compose ps 2>/dev/null || echo "  (compose not up)"

echo "== exposed ports (0.0.0.0) =="
ss -tlnp 2>/dev/null | grep -E ":(${https}|${http})\b" || echo "  no listeners on ${https}/${http}"

echo "== TLS reachability (https ${https}) =="
if command -v openssl >/dev/null 2>&1; then
	if echo | timeout 8 openssl s_client -connect "127.0.0.1:${https}" -servername localhost 2>/dev/null | grep -q "Verify return code: 0"; then
		echo "  OK — TLS handshake verified on ${https}"; exit 0
	else
		echo "  not answering on ${https} (stack down? still starting?)"; exit 1
	fi
else
	echo "  openssl not installed; skipping TLS probe"
fi
