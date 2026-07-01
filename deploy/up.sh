#!/usr/bin/env bash
#
# deploy/up.sh — HelixCode edge boot engine (TLS-mode-aware).
#
# Purpose      : render the Caddyfile per TLS_MODE (edge TLS + the helix-auth
#                forward-auth gate + reverse_proxy to host-native code-server),
#                prepare the self-signed cert (LAN default), and bring the
#                containerized Caddy edge up (rootless). code-server AND
#                helix-auth run host-native as the real user (systemd --user);
#                they are installed by scripts/install-auth.sh, NOT by this script.
# Usage        : ./up.sh            (normal boot)
#                UP_SH_RENDER_ONLY=1 CADDYFILE_OUT=/tmp/Caddyfile TLS_MODE=... \
#                  ./up.sh          (render the Caddyfile ONLY — no cert, no boot;
#                                    the seam tests/types/tls_letsencrypt.sh uses)
# Inputs       : deploy/.env — PORT_PREFIX
#                TLS_MODE CS_DOMAIN ACME_EMAIL ACME_CA_URL ACME_CA_ROOT
#                ACME_DNS_PROVIDER ACME_DNS_API_TOKEN (secret; never echoed).
#                Editor auth is host-native: helix-auth verifies an ssh-key
#                challenge-response signature — there is NO password parameter here.
#                HELIX_AUTH_ACCOUNT / PROJECTS_ROOT configure the host-native
#                units (consumed by scripts/install-auth.sh, not by up.sh).
# Outputs      : ./Caddyfile (rendered idempotently), Caddy edge boot.
# Side-effects : may write tls/ (self-signed mode), starts the Caddy container.
# Cross-refs   : docs/guides/TLS.md ; §11.4.10 (no secret echo) §11.4.69 §11.4.123
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${PORT_PREFIX:=52}"
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
# emit_app_routing — the shared app-site routing body, IDENTICAL for every
# TLS_MODE (only the TLS block above it differs). This is the ONLY thing that
# changed vs the old single `reverse_proxy code-server:8080` line: the site now
# (1) routes /login, /logout + the auth static assets to helix-auth, and
# (2) forward-auth-gates everything else, proxying to host-native code-server
# ONLY when the gate returns 2xx (fail-closed). Both upstreams are host-native
# and reached from the rootless-podman Caddy container over the host gateway via
# host.containers.internal (code-server 127.0.0.1:8080, helix-auth :8081).
# The routing is emitted at one-tab (site-body) indentation so it drops cleanly
# into both the :443 self-signed site and the $CS_DOMAIN ACME site.
emit_app_routing() {
  cat <<'ROUTING'
	# /login, /logout and the auth service's own static assets are served by
	# helix-auth directly (NOT behind the gate — needed in order to log in).
	@helix_auth path /login /login/* /logout /auth /healthz /_helixauth/*
	handle @helix_auth {
		# reverse_proxy sets X-Forwarded-For by default, so the gate sees the real
		# client IP on /login too and rate-limits login attempts per client
		# (HELIX_AUTH_TRUST_FORWARDED_FOR=true keys on the rightmost XFF entry).
		reverse_proxy host.containers.internal:8081
	}
	# Defense-in-depth: block code-server's built-in port-proxy feature at the edge
	# (CVE-2025-47269 class — session-cookie exfil via a crafted /proxy/ URL;
	# FINDINGS Angle 2/4). HelixCode does not use it => 403 so such a request never
	# reaches code-server, even though 4.117.0 is already patched.
	@cs_proxy path /proxy/* /absproxy/*
	handle @cs_proxy {
		respond 403
	}
	# Everything else is the protected editor: forward-auth check first (a copy
	# of the request goes to helix-auth's /auth; 2xx => allow, else Caddy
	# returns the gate's response — down/erroring gate => denied, never bypassed),
	# then reverse_proxy to host-native code-server on success.
	handle {
		# X-Helix-User integrity + per-client rate-limit keying.
		# (1) A CLIENT-supplied X-Helix-User MUST NEVER reach code-server: the gate
		#     sets X-Helix-User on its /auth RESPONSE and forward_auth's copy_headers
		#     propagates ONLY that auth-derived value. We DELETE any inbound client
		#     value FIRST (request_header -X-Helix-User) so the request forward_auth
		#     copies onto is already clean — closing the copy_headers identity-
		#     injection class (Caddy GHSA-7r4p-vjf4-gxv4): even if the gate ever
		#     returned 2xx WITHOUT setting the header, no client value could survive.
		#     NB: deleting on the code-server reverse_proxy (header_up -X-Helix-User)
		#     would instead strip the gate's value that copy_headers just set on the
		#     request — so the strip MUST precede forward_auth; the `route` pins that
		#     execution order (handle sorts by directive order, route runs in written
		#     order).
		# (2) X-Forwarded-For: Caddy is the SOLE trusted hop (no trusted_proxies), so
		#     it ignores client-sent XFF and sets it to the real client IP, which
		#     forward_auth passes to the gate; the gate keys its per-client rate-limit
		#     on the RIGHTMOST XFF entry (HELIX_AUTH_TRUST_FORWARDED_FOR=true).
		route {
			request_header -X-Helix-User
			forward_auth host.containers.internal:8081 {
				uri /auth
				copy_headers X-Helix-User
			}
			reverse_proxy host.containers.internal:8080
		}
	}
ROUTING
}

# self-signed: the TLS/global block is byte-for-byte the original static-cert
# config (regression-safe; for PORT_PREFIX=52 the redirect port is 52443 exactly
# as the committed file) — only the app routing (emit_app_routing) replaces the
# former single `reverse_proxy code-server:8080` line.
render_selfsigned() {
  local rp="${PORT_PREFIX}443"
  cat > "$1" <<EOF
{
	auto_https disable_redirects
	# HTTP/3 (QUIC) explicit at the edge: h1 (HTTP/1.1) + h2 (HTTP/2 over TLS) +
	# h3 (HTTP/3 over QUIC/UDP). Caddy already serves h3 on :443 by default; this
	# pins it explicitly. QUIC needs UDP/443 PUBLISHED — see compose.codeserver.yml
	# (0.0.0.0:52443:443/udp) alongside the TCP mapping.
	servers {
		protocols h1 h2 h3
	}
}
:443 {
	# Static self-signed cert (SAN: localhost + 127.0.0.1 + detected LAN IPs),
	# generated per boot by up.sh. Served for all SNI so LAN-by-IP access works
	# inside the port-mapped container (a bare \`tls internal\` site has no
	# hostnames to issue a leaf cert for and aborts every handshake).
	tls /etc/caddy/tls/site.crt /etc/caddy/tls/site.key
	# br (Brotli) is provided by the custom caddy/Dockerfile image (ueffel/caddy-brotli);
	# stock caddy:2 has only zstd+gzip. Caddy negotiates per the client's Accept-Encoding.
	encode zstd br gzip
EOF
  emit_app_routing >> "$1"
  cat >> "$1" <<EOF
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
    # HTTP/3 (QUIC) explicit at the edge (same as self-signed; needs UDP/443 —
    # see compose.codeserver.yml 0.0.0.0:52443:443/udp).
    printf '\tservers {\n'
    printf '\t\tprotocols h1 h2 h3\n'
    printf '\t}\n'
    printf '}\n\n'
    printf '%s {\n' "$CS_DOMAIN"
    printf '\tencode zstd br gzip\n'   # br from the custom caddy/Dockerfile image
    if [ -n "$ACME_DNS_PROVIDER" ]; then
      printf '\ttls %s {\n' "$ACME_EMAIL"
      printf '\t\tdns %s {env.ACME_DNS_API_TOKEN}\n' "$ACME_DNS_PROVIDER"
      printf '\t}\n'
    fi
    emit_app_routing
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

# Editor auth is host-native: helix-auth verifies an ssh-key challenge-response
# signature at login (nothing stored) — there is NO CODE_SERVER_PASSWORD.
# code-server + helix-auth run as systemd --user services (installed by
# scripts/install-auth.sh); this script brings up ONLY the containerized Caddy
# edge (§11.4.76 — Caddy stays containerized). code-server's projects workspace
# + the watcherExclude settings are handled host-side by the systemd unit
# (${PROJECTS_ROOT}) and scripts/install-auth.sh, not by a container volume.
#
# Drop any stale container-code-server projects override so the caddy-only
# compose (and lib.sh's hc_compose) never merges a now-invalid service fragment.
rm -f compose.projects.yml 2>/dev/null || true

RT="podman compose"; command -v podman >/dev/null || RT="docker compose"
echo "runtime: $RT  (TLS_MODE=$TLS_MODE)"

$RT -f compose.codeserver.yml up -d --build
$RT -f compose.codeserver.yml ps
