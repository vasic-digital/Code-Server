#!/usr/bin/env bash
# scripts/install.sh — one-shot HelixCode installer (reproducible everywhere).
#
# Purpose:      Full install in one command: preflight -> configure (if needed)
#               -> start the stack -> install the boot-survival systemd service.
#               Run this on any host to get an identical, reboot-persistent
#               deployment.
# Usage:        scripts/install.sh                # user service (rootless, default)
#               scripts/install.sh --system       # system service (needs sudo)
#               scripts/install.sh --no-service   # install without boot service
# Inputs:       deploy/.env (created by the wizard if absent)
# Outputs:      a running stack + an enabled systemd unit (unless --no-service)
# Side-effects: writes deploy/.env (via setup.sh if missing); starts containers;
#               installs + enables a systemd unit; (user) enables linger
# Dependencies: bash; podman or docker; systemd; scripts/{doctor,setup,start,
#               install-service}.sh
# Cross-references: docs/scripts/README.md, scripts/install-service.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WITH_SERVICE=1; SYSTEM_FLAG=""
for a in "$@"; do
	case "$a" in
		--no-service) WITH_SERVICE=0 ;;
		--system)     SYSTEM_FLAG="--system" ;;
		-h|--help)    sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*)            hc_err "unknown arg: $a"; exit 2 ;;
	esac
done

hc_info "== HelixCode install =="

# 1. Preflight (advisory — 'ports in use' is expected on re-install; a missing
#    runtime is surfaced clearly by start.sh below).
"$HC_ROOT/scripts/doctor.sh" || hc_warn "doctor reported issues (see above) — continuing"

# 2. Configure if not already configured.
if [ ! -f "$HC_DEPLOY/.env" ]; then
	hc_info "no deploy/.env — launching setup wizard"
	"$HC_ROOT/scripts/setup.sh"
else
	hc_info "using existing deploy/.env"
fi

# 3. Bring the stack up.
"$HC_ROOT/scripts/start.sh"

# 4. Boot-survival service (default on — makes the install reboot-persistent).
if [ "$WITH_SERVICE" -eq 1 ]; then
	hc_info "installing boot-survival service…"
	# shellcheck disable=SC2086
	"$HC_ROOT/scripts/install-service.sh" $SYSTEM_FLAG
else
	hc_info "skipping boot service (--no-service)"
fi

hc_info "install complete. Manage with scripts/{status,logs,stop,set-password}.sh"
