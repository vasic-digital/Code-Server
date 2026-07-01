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
  IFS=':' read -ra _ps <<< "$PROJECTS"
  for p in "${_ps[@]}"; do
    [ -n "$p" ] || continue
    echo "      - ${p}:/home/coder/projects/$(basename "$p"):Z"
  done
} > compose.projects.yml
RT="podman compose"; command -v podman >/dev/null || RT="docker compose"
echo "runtime: $RT"
$RT -f compose.codeserver.yml -f compose.projects.yml up -d --build
$RT -f compose.codeserver.yml -f compose.projects.yml ps
