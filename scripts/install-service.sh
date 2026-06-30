#!/usr/bin/env bash
# scripts/install-service.sh — install HelixCode as a systemd service.
#
# Purpose:      Register a systemd unit so the stack starts on boot/login and
#               can be managed with systemctl. Prefers a rootless user service
#               (no sudo); use --system for a root/system unit.
# Usage:        scripts/install-service.sh           # user service (default)
#               scripts/install-service.sh --system  # system service (needs sudo)
# Inputs:       deploy/.env must already exist (run scripts/setup.sh first)
# Outputs:      a 'helixcode' systemd unit, enabled + started
# Side-effects: writes a unit file; enables + starts it; (user) enables linger so
#               it survives logout
# Dependencies: bash; systemd (systemctl); scripts/start.sh + stop.sh
# Cross-references: docs/scripts/README.md, scripts/uninstall-service.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hc_require_env
command -v systemctl >/dev/null 2>&1 || { hc_err "systemctl not found (systemd required)"; exit 1; }

SYSTEM=0; [ "${1:-}" = "--system" ] && SYSTEM=1
UNIT_BODY="[Unit]
Description=HelixCode containerized code-server stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$HC_ROOT
ExecStart=$HC_ROOT/scripts/start.sh
ExecStop=$HC_ROOT/scripts/stop.sh
TimeoutStartSec=600

[Install]
WantedBy=default.target"

if [ "$SYSTEM" -eq 1 ]; then
	echo "$UNIT_BODY" | sudo tee /etc/systemd/system/helixcode.service >/dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable --now helixcode.service
	hc_info "installed system service: systemctl status helixcode"
else
	mkdir -p "$HOME/.config/systemd/user"
	printf '%s\n' "$UNIT_BODY" > "$HOME/.config/systemd/user/helixcode.service"
	systemctl --user daemon-reload
	systemctl --user enable --now helixcode.service
	loginctl enable-linger "$(id -un)" 2>/dev/null || hc_warn "could not enable linger (service may stop on logout)"
	hc_info "installed user service: systemctl --user status helixcode"
fi
