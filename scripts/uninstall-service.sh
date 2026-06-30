#!/usr/bin/env bash
# scripts/uninstall-service.sh — remove the HelixCode systemd service.
#
# Purpose:      Stop, disable, and delete the systemd unit created by
#               install-service.sh (user unit by default; --system for root).
# Usage:        scripts/uninstall-service.sh           # user service
#               scripts/uninstall-service.sh --system  # system service (sudo)
# Inputs:       none
# Outputs:      removed unit; stack stopped
# Side-effects: disables + removes the unit; stops the running stack
# Dependencies: bash; systemd (systemctl)
# Cross-references: docs/scripts/README.md, scripts/install-service.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v systemctl >/dev/null 2>&1 || { hc_err "systemctl not found"; exit 1; }
if [ "${1:-}" = "--system" ]; then
	sudo systemctl disable --now helixcode.service 2>/dev/null || true
	sudo rm -f /etc/systemd/system/helixcode.service
	sudo systemctl daemon-reload
	hc_info "removed system service helixcode"
else
	systemctl --user disable --now helixcode.service 2>/dev/null || true
	rm -f "$HOME/.config/systemd/user/helixcode.service"
	systemctl --user daemon-reload
	hc_info "removed user service helixcode"
fi
