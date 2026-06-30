#!/usr/bin/env bash
# scripts/doctor.sh — preflight health check for a HelixCode host.
#
# Purpose:      Verify the host can run the stack: container runtime present,
#               deploy/.env present + valid, exposed ports free, basic resources.
# Usage:        scripts/doctor.sh
# Inputs:       deploy/.env (PORT_PREFIX)
# Outputs:      a checklist with OK/WARN/FAIL lines; exit 0 only if no FAIL
# Side-effects: none (read-only)
# Dependencies: bash; podman or docker; ss; free; df
# Cross-references: docs/scripts/README.md, scripts/setup.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fails=0
ok(){ printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
warn(){ printf '  \033[1;33mWARN\033[0m %s\n' "$*"; }
bad(){ printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }

echo "== container runtime =="
if command -v podman >/dev/null 2>&1; then ok "podman $(podman --version 2>/dev/null | awk '{print $3}')"
elif command -v docker >/dev/null 2>&1; then ok "docker present"
else bad "no podman/docker on PATH"; fi

echo "== config =="
if [ -f "$HC_DEPLOY/.env" ]; then ok "deploy/.env present"; else bad "deploy/.env missing — run scripts/setup.sh"; fi
prefix="$(hc_prefix)"
if [[ "$prefix" =~ ^[0-9]+$ ]] && [ $((prefix*1000+999)) -le 65535 ]; then ok "port prefix $prefix valid"; else bad "port prefix '$prefix' invalid (PREFIX*1000+999 > 65535)"; fi

echo "== exposed ports free =="
for p in "${prefix}443" "${prefix}080"; do
	if ss -tlnH "( sport = :$p )" 2>/dev/null | grep -q .; then warn "port $p already in use (ok if it's our stack)"; else ok "port $p free"; fi
done

echo "== resources =="
avail=$(df -BG --output=avail "$HC_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
[ "${avail:-0}" -ge 5 ] && ok "disk ${avail}G free" || warn "low disk (${avail:-?}G free)"
freem=$(free -m 2>/dev/null | awk '/Mem:/{print $7}')
[ "${freem:-0}" -ge 512 ] && ok "memory ${freem}M available" || warn "low memory (${freem:-?}M available)"

echo "----"
[ "$fails" -eq 0 ] && { echo "doctor: PASS"; exit 0; } || { echo "doctor: $fails FAIL(s)"; exit 1; }
