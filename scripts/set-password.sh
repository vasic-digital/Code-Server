#!/usr/bin/env bash
# scripts/set-password.sh — change the code-server login password.
#
# Purpose:      Update CODE_SERVER_PASSWORD in deploy/.env (preserving the port
#               prefix + projects) and apply it by recreating the stack so the
#               new password takes effect immediately.
# Usage:        scripts/set-password.sh                 # interactive (recommended)
#               NEW_PASSWORD=… scripts/set-password.sh  # non-interactive (env)
#               scripts/set-password.sh --password …    # non-interactive (argv*)
#                 *argv is visible in the process list — prefer interactive/env.
# Inputs:       new password (prompt / NEW_PASSWORD env / --password); existing
#               deploy/.env for PORT_PREFIX + PROJECTS
# Outputs:      rewritten deploy/.env (mode 600, git-ignored); restarted stack
# Side-effects: rewrites deploy/.env; if the stack is running, restarts it
# Dependencies: bash; podman or docker; scripts/lib.sh, scripts/restart.sh
# Cross-references: docs/scripts/README.md, scripts/setup.sh, scripts/install.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hc_require_env
hc_load_env

NEWPW=""; NONINT=0
case "${1:-}" in
	-h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
	--password) NEWPW="${2:-}"; NONINT=1 ;;
	"") ;;
	*) hc_err "unknown arg: $1"; exit 2 ;;
esac
if [ -z "$NEWPW" ] && [ -n "${NEW_PASSWORD:-}" ]; then NEWPW="$NEW_PASSWORD"; NONINT=1; fi

if [ "$NONINT" -eq 0 ]; then
	while :; do
		read -r -s -p "New login password: " p1; echo
		read -r -s -p "Confirm new password: " p2; echo
		[ -n "$p1" ] && [ "$p1" = "$p2" ] && { NEWPW="$p1"; break; }
		hc_warn "passwords empty or do not match — try again"
	done
fi
[ -n "$NEWPW" ] || { hc_err "password must not be empty"; exit 2; }

# Atomic rewrite (§11.4.6): write a temp file then rename it over deploy/.env.
# A plain `cat > .env` truncates-then-writes, so an interrupted run (SIGINT,
# crash, disk-full mid-write) leaves a torn / 0-byte .env and up.sh then aborts
# on the missing CODE_SERVER_PASSWORD. rename(2) on the same filesystem is
# atomic — readers always see either the whole old file or the whole new one.
umask 077
_env_tmp="$HC_DEPLOY/.env.tmp.$$"
trap 'rm -f "$_env_tmp"' EXIT
cat > "$_env_tmp" <<ENV
# HelixCode deploy config — updated by scripts/set-password.sh. NOT committed.
PORT_PREFIX=${PORT_PREFIX:-52}
CODE_SERVER_PASSWORD=$NEWPW
PROJECTS=${PROJECTS:-}
ENV
chmod 600 "$_env_tmp"
mv -f "$_env_tmp" "$HC_DEPLOY/.env"
hc_info "login password updated in deploy/.env (mode 600, atomic write)"

if hc_compose ps 2>/dev/null | grep -q code-server; then
	hc_info "restarting stack to apply the new password…"
	"$HC_ROOT/scripts/restart.sh"
	hc_info "new password is now active."
else
	hc_info "stack not running — new password applies on next scripts/start.sh"
fi
