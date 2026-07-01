#!/usr/bin/env bash
#
# deploy/up.sh — HelixCode edge boot engine (TLS-mode-aware).
#
# Purpose      : render the Caddyfile per TLS_MODE, prepare the self-signed cert
#                (LAN default), generate compose.projects.yml from $PROJECTS,
#                seed code-server settings, and bring the stack up (rootless).
# Usage        : ./up.sh            (normal boot)
#                UP_SH_RENDER_ONLY=1 CADDYFILE_OUT=/tmp/Caddyfile TLS_MODE=... \
#                  ./up.sh          (render the Caddyfile ONLY — no cert, no boot;
#                                    the seam tests/types/tls_letsencrypt.sh uses)
# Inputs       : deploy/.env — PORT_PREFIX PROJECTS CODE_SERVER_PASSWORD
#                TLS_MODE CS_DOMAIN ACME_EMAIL ACME_CA_URL ACME_CA_ROOT
#                ACME_DNS_PROVIDER ACME_DNS_API_TOKEN (secret; never echoed).
# Outputs      : ./Caddyfile (rendered idempotently), compose.projects.yml, boot.
# Side-effects : may write tls/ (self-signed mode), starts containers.
# Cross-refs   : docs/guides/TLS.md ; §11.4.10 (no secret echo) §11.4.69 §11.4.123
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${PORT_PREFIX:=52}"; : "${PROJECTS:=}"
: "${TLS_MODE:=self-signed}"
: "${CS_DOMAIN:=}"; : "${ACME_EMAIL:=}"; : "${ACME_CA_URL:=}"; : "${ACME_CA_ROOT:=}"
: "${ACME_DNS_PROVIDER:=}"   # ACME_DNS_API_TOKEN intentionally NOT defaulted/echoed (§11.4.10)
: "${CADDYFILE_OUT:=Caddyfile}"
RENDER_ONLY="${UP_SH_RENDER_ONLY:-0}"

# ---- self-signed cert (LAN default) --------------------------------------
# Static self-signed edge cert. Caddy serves this for all SNI on :443 (a bare
# `tls internal` site has no hostnames and aborts every handshake). Regenerated
# only when missing or when a LAN IP is not yet covered — so browser trust
# stays stable across restarts.
ensure_self_signed_cert() {
  mkdir -p tls
  local LANIPS need=0 ip SANS
  LANIPS="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)"
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
}

# ---- Caddyfile renderers (per TLS_MODE) ----------------------------------
# self-signed: byte-for-byte the original static-cert config (regression-safe;
# for PORT_PREFIX=52 the redirect port is 52443 exactly as the committed file).
render_selfsigned() {
  local rp="${PORT_PREFIX}443"
  cat > "$1" <<EOF
{
	auto_https disable_redirects
}
:443 {
	# Static self-signed cert (SAN: localhost + 127.0.0.1 + detected LAN IPs),
	# generated per boot by up.sh. Served for all SNI so LAN-by-IP access works
	# inside the port-mapped container (a bare \`tls internal\` site has no
	# hostnames to issue a leaf cert for and aborts every handshake).
	tls /etc/caddy/tls/site.crt /etc/caddy/tls/site.key
	encode zstd gzip
	reverse_proxy code-server:8080
}
:80 {
	redir https://{host}:${rp}{uri} permanent
}
EOF
}

# ACME modes: Caddy automatic HTTPS. Named-host site => Caddy auto-issues +
# auto-renews (~30d pre-expiry) via the chosen CA and auto-redirects :80->:443.
# The DNS-01 token is referenced as {env.ACME_DNS_API_TOKEN} — read from the
# container env (compose passthrough), NEVER written into this tracked file.
render_acme() {
  local out="$1"
  {
    printf '{\n'
    printf '\temail %s\n' "$ACME_EMAIL"
    case "$TLS_MODE" in
      letsencrypt)          [ -n "$ACME_CA_URL" ] && printf '\tacme_ca %s\n' "$ACME_CA_URL" ;;
      letsencrypt-staging)  printf '\tacme_ca %s\n' "https://acme-staging-v02.api.letsencrypt.org/directory" ;;
      internal-acme)
        printf '\tacme_ca %s\n' "$ACME_CA_URL"
        [ -n "$ACME_CA_ROOT" ] && printf '\tacme_ca_root %s\n' "$ACME_CA_ROOT"
        ;;
    esac
    printf '}\n\n'
    printf '%s {\n' "$CS_DOMAIN"
    printf '\tencode zstd gzip\n'
    if [ -n "$ACME_DNS_PROVIDER" ]; then
      printf '\ttls %s {\n' "$ACME_EMAIL"
      printf '\t\tdns %s {env.ACME_DNS_API_TOKEN}\n' "$ACME_DNS_PROVIDER"
      printf '\t}\n'
    fi
    printf '\treverse_proxy code-server:8080\n'
    printf '}\n'
  } > "$out"
}

render_caddyfile() {
  local tmp; tmp="$(mktemp)"
  case "$TLS_MODE" in
    self-signed)                            render_selfsigned "$tmp" ;;
    letsencrypt|letsencrypt-staging|internal-acme) render_acme "$tmp" ;;
    *) echo "up.sh: unknown TLS_MODE '$TLS_MODE' (self-signed|letsencrypt|letsencrypt-staging|internal-acme)" >&2; rm -f "$tmp"; exit 1 ;;
  esac
  if [ -f "$CADDYFILE_OUT" ] && cmp -s "$tmp" "$CADDYFILE_OUT"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$CADDYFILE_OUT"; echo "rendered $CADDYFILE_OUT (TLS_MODE=$TLS_MODE)"
  fi
}

# ---- TLS mode dispatch ----------------------------------------------------
case "$TLS_MODE" in
  self-signed)
    [ "$RENDER_ONLY" = 1 ] || ensure_self_signed_cert
    ;;
  letsencrypt|letsencrypt-staging|internal-acme)
    [ -n "$CS_DOMAIN" ]  || { echo "up.sh: TLS_MODE=$TLS_MODE requires CS_DOMAIN in .env" >&2; exit 1; }
    [ -n "$ACME_EMAIL" ] || { echo "up.sh: TLS_MODE=$TLS_MODE requires ACME_EMAIL in .env" >&2; exit 1; }
    [ "$TLS_MODE" = internal-acme ] && [ -z "$ACME_CA_URL" ] && { echo "up.sh: internal-acme requires ACME_CA_URL in .env" >&2; exit 1; }
    ;;
  *) echo "up.sh: unknown TLS_MODE '$TLS_MODE'" >&2; exit 1 ;;
esac

render_caddyfile

if [ "$RENDER_ONLY" = 1 ]; then
  echo "render-only: wrote $CADDYFILE_OUT for TLS_MODE=$TLS_MODE (no cert, no boot)"
  exit 0
fi

: "${CODE_SERVER_PASSWORD:?set CODE_SERVER_PASSWORD in deploy/.env}"

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
echo "runtime: $RT  (TLS_MODE=$TLS_MODE)"

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
