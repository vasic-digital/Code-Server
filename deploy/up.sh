#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${PORT_PREFIX:=52}"; : "${PROJECTS:=}"
: "${CODE_SERVER_PASSWORD:?set CODE_SERVER_PASSWORD in deploy/.env}"

# Static self-signed edge cert. Caddy serves this for all SNI on :443 (a bare
# `tls internal` site has no hostnames and aborts every handshake). Regenerated
# only when missing or when a LAN IP is not yet covered — so browser trust
# stays stable across restarts.
mkdir -p tls
LANIPS="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)"
need=0
{ [ -s tls/site.crt ] && [ -s tls/site.key ]; } || need=1
if [ "$need" -eq 0 ]; then
  for ip in $LANIPS; do
    openssl x509 -in tls/site.crt -noout -text 2>/dev/null | grep -q "IP Address:$ip" || need=1
  done
fi
if [ "$need" -eq 1 ]; then
  SANS="DNS:localhost,DNS:$(hostname 2>/dev/null || echo helixcode),IP:127.0.0.1"
  for ip in $LANIPS; do SANS="$SANS,IP:$ip"; done
  openssl req -x509 -newkey rsa:2048 -nodes -keyout tls/site.key -out tls/site.crt \
    -days 825 -subj "/CN=helixcode" -addext "subjectAltName=$SANS" >/dev/null 2>&1
  chmod 600 tls/site.key
  echo "generated self-signed TLS cert (SAN: $SANS)"
fi
{
  echo "services:"
  echo "  code-server:"
  echo "    volumes:"
  echo "      - cs-config:/home/coder/.config"
  echo "      - cs-data:/home/coder/.local/share/code-server"
  IFS=':' read -ra _ps <<< "$PROJECTS"
  for p in "${_ps[@]}"; do
    [ -n "$p" ] || continue
    echo "      - ${p}:/home/coder/projects/$(basename "$p"):Z"
  done
} > compose.projects.yml
RT="podman compose"; ENG="podman"; command -v podman >/dev/null || { RT="docker compose"; ENG="docker"; }
echo "runtime: $RT"

# Pre-seed default code-server settings (files.watcherExclude — prevents the
# inotify "unable to watch for file changes" warning on large project trees)
# into the cs-data volume BEFORE code-server starts, so the fix applies on the
# very first boot (not only after a restart). Seeds only if absent so operator
# edits made in the UI are never clobbered. The compose project is "deploy"
# (this dir), so the volume is "deploy_cs-data".
$ENG volume create deploy_cs-data >/dev/null 2>&1 || true
VMP="$($ENG volume inspect deploy_cs-data --format '{{.Mountpoint}}' 2>/dev/null || true)"
if [ -n "$VMP" ] && [ ! -f "$VMP/User/settings.json" ]; then
  mkdir -p "$VMP/User" 2>/dev/null \
    && cp code-server/settings.default.json "$VMP/User/settings.json" 2>/dev/null \
    && echo "seeded code-server watcherExclude settings"
fi

$RT -f compose.codeserver.yml -f compose.projects.yml up -d --build
$RT -f compose.codeserver.yml -f compose.projects.yml ps
