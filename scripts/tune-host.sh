#!/usr/bin/env bash
# scripts/tune-host.sh — raise host inotify limits for large project trees.
#
# Purpose:      Install deploy/sysctl/99-helixcode-inotify.conf into
#               /etc/sysctl.d/ and apply it, so code-server can watch large
#               workspaces without the "unable to watch for file changes"
#               (ENOSPC) warning. inotify limits are a host-kernel, per-UID
#               resource (not per-container), so this must be set on the host.
# Usage:        sudo scripts/tune-host.sh          # install persistently + apply
#               scripts/tune-host.sh --show        # print current vs target
# Inputs:       deploy/sysctl/99-helixcode-inotify.conf
# Outputs:      /etc/sysctl.d/99-helixcode-inotify.conf (persistent) + live values
# Side-effects: writes an /etc/sysctl.d drop-in and runs sysctl (needs root)
# Dependencies: bash; sysctl; root (sudo) to apply
# Cross-references: docs/scripts/README.md, scripts/install.sh, deploy/sysctl/
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SRC="$HC_DEPLOY/sysctl/99-helixcode-inotify.conf"
DST="/etc/sysctl.d/99-helixcode-inotify.conf"

show() {
	printf 'inotify limits (current -> target):\n'
	while IFS= read -r line; do
		case "$line" in
			fs.inotify.*)
				key="${line%%=*}"; key="$(echo "$key" | tr -d ' ')"
				target="${line##*=}"; target="$(echo "$target" | tr -cd '0-9')"
				proc="/proc/sys/$(echo "$key" | tr '.' '/')"
				cur="$(cat "$proc" 2>/dev/null || echo '?')"
				printf '  %-32s %s -> %s\n' "$key" "$cur" "$target"
				;;
		esac
	done < "$SRC"
}

case "${1:-}" in
	-h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
	--show)    show; exit 0 ;;
	"")        ;;
	*)         hc_err "unknown arg: $1"; exit 2 ;;
esac

[ -f "$SRC" ] || { hc_err "missing $SRC"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
	hc_warn "not root — cannot install/apply host sysctl. Run:"
	printf '    sudo cp %s %s\n    sudo sysctl --system\n' "$SRC" "$DST"
	hc_info "current values:"; show
	exit 1
fi

install -m 0644 "$SRC" "$DST"
sysctl -p "$DST" >/dev/null
hc_info "installed $DST and applied. Effective values:"
show
