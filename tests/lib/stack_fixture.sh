#!/usr/bin/env bash
#
# tests/lib/stack_fixture.sh — live-stack fixture for HelixCode test suites.
#
# On-demand infrastructure (§11.4.76): a suite that needs the running stack
# calls `hc_stack_up` which brings it up via scripts/start.sh if it is not
# already running, so tests never require an operator to boot infra by hand.
#
# The INSTALLED stack (compose project "deploy") is a SHARED, single-owner
# resource (§11.4.119): read-mostly helpers here are safe to call from any
# suite, but DESTRUCTIVE tests (chaos kills, floods, Caddy reconfig) MUST be
# serialized by the main-stream executor — never run concurrently against it.
#
# Purpose      : resolve stack endpoints/creds + boot/login/exec helpers
# Inputs       : deploy/.env (PORT_PREFIX, CODE_SERVER_PASSWORD, PROJECTS)
# Outputs      : env vars HC_HTTPS/HC_HTTP/HC_BASE/HC_ENGINE/HC_CS/HC_CADDY
# Side-effects : hc_stack_up may start containers; helpers never delete data
# Dependencies : bash, curl, podman|docker ; openssl for TLS probes
# Cross-refs    : §11.4.76 §11.4.119 §11.4.10 ; harness.sh ; scripts/start.sh
set -uo pipefail

: "${HC_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# ---- runtime engine ------------------------------------------------------
if command -v podman >/dev/null 2>&1; then HC_ENGINE=podman; else HC_ENGINE=docker; fi
HC_CS="deploy_code-server_1"
HC_CADDY="deploy_caddy_1"

# ---- config from deploy/.env (never printed; §11.4.10) -------------------
hc_load_env() {
  HC_PORT_PREFIX=52; HC_PASSWORD=""; HC_PROJECTS=""
  if [ -f "$HC_ROOT/deploy/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$HC_ROOT/deploy/.env"; set +a
    HC_PORT_PREFIX="${PORT_PREFIX:-52}"
    HC_PASSWORD="${CODE_SERVER_PASSWORD:-}"
    HC_PROJECTS="${PROJECTS:-}"
  fi
  HC_HTTPS="${HC_PORT_PREFIX}443"
  HC_HTTP="${HC_PORT_PREFIX}080"
  HC_BASE="https://127.0.0.1:${HC_HTTPS}"
  export HC_PORT_PREFIX HC_HTTPS HC_HTTP HC_BASE
}

# ---- readiness -----------------------------------------------------------
# hc_https_code <path> -> HTTP status via curl -k (self-signed tolerant)
hc_https_code() { curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$HC_BASE${1:-/}" 2>/dev/null || echo 000; }

hc_is_up() {
  "$HC_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -q "^$HC_CADDY$" || return 1
  [ "$(hc_https_code /healthz)" != "000" ] || [ "$(hc_https_code /)" != "000" ]
}

# hc_stack_up: ensure the installed stack is reachable; boot on demand.
hc_stack_up() {
  hc_load_env
  if hc_is_up; then return 0; fi
  ( cd "$HC_ROOT" && bash scripts/start.sh ) >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    [ "$(hc_https_code /)" != "000" ] && return 0
    sleep 2
  done
  return 1
}

# ---- auth journey --------------------------------------------------------
# hc_login_code <password> -> HTTP status of POST /login (302 = correct pw)
hc_login_code() {
  curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --data-urlencode "password=${1:-}" "$HC_BASE/login" 2>/dev/null || echo 000
}

# hc_login_headers <password> <outfile> -> writes response headers (Set-Cookie)
hc_login_headers() {
  curl -k -s -D "${2:-/dev/stdout}" -o /dev/null --max-time 10 \
    --data-urlencode "password=${1:-}" "$HC_BASE/login" 2>/dev/null
}

# ---- container exec (read/write proof inside code-server) -----------------
hc_cs_exec() { "$HC_ENGINE" exec "$HC_CS" sh -c "$*" 2>&1; }

# hc_caddy_cipher <outfile> -> negotiated TLS cipher line via openssl
hc_tls_probe() {
  local out="${1:-/dev/stdout}"
  { echo | openssl s_client -connect "127.0.0.1:${HC_HTTPS}" -servername helixcode 2>/dev/null \
      | grep -iE 'protocol|cipher|subject|issuer' ; } > "$out" 2>&1 || true
}
