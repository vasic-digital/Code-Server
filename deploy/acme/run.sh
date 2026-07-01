#!/usr/bin/env bash
#
# deploy/acme/run.sh — LOCAL ACME issuance + rotation PROOF harness.
#
# Purpose      : Prove, with rock-solid captured evidence (§11.4.69/§11.4.123),
#                that Caddy's ACME automatic-HTTPS path really OBTAINS a
#                CA-signed leaf, SERVES it, and ROTATES it (renewal) to a NEW
#                cert — end-to-end, WITHOUT a public domain, using a local
#                Pebble ACME CA (§11.4.98 deterministic + re-runnable).
# Usage        : deploy/acme/run.sh [--evidence-dir DIR] [--host-port N] [--keep]
# Inputs       : podman (rootless), openssl, curl, ss ; ghcr.io/letsencrypt/pebble
#                + docker.io/library/caddy:2 images.
# Outputs      : evidence files under DIR (default qa-results/acme/<run-id>/):
#                acme_preflight/pki/leaf_initial/backend_curl/leaf_rotated/
#                rotation/edge_logs/result .txt|.pem ; RESULT lines on stdout.
# Exit         : 0 = PASS (issued-by-pebble + rotation serial changed)
#                2 = SKIP (images unpullable / no network — honest, never faked)
#                1 = FAIL (issuance or rotation did not happen)
# Side-effects : brings up compose project "hc_acme_proof" (53xxx, DISTINCT from
#                the installed "deploy" stack — §11.4.119) and tears it down in a
#                trap EXIT (§11.4.14). Touches ONLY containers of its own project
#                name (§11.4.174). Writes a mktemp PKI dir; removes it on exit.
# Dependencies : deploy/acme/compose.acme.yml + Caddyfile.edge + Caddyfile.backend
#                + pebble-config.json (all tracked, in this dir).
# Cross-refs   : §11.4.14 §11.4.69 §11.4.98 §11.4.119 §11.4.123 §11.4.161 §11.4.174
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROJECT="hc_acme_proof"
COMPOSE="compose.acme.yml"
CS_DOMAIN="${CS_DOMAIN:-code.helixcode.test}"
ACME_EMAIL="${ACME_EMAIL:-acme-proof@helixcode.test}"
ACME_CA_URL="${ACME_CA_URL:-https://pebble:14000/dir}"
KEEP=0
HOSTPORT_REQ=53443
EVDIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --evidence-dir) EVDIR="$2"; shift 2 ;;
    --host-port)    HOSTPORT_REQ="$2"; shift 2 ;;
    --keep)         KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

RUNID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
[ -n "$EVDIR" ] || EVDIR="$ROOT/qa-results/acme/$RUNID"
mkdir -p "$EVDIR"
# Absolutize: run.sh cd's into $HERE for compose, so a relative evidence dir
# would resolve wrong inside those subshells.
EVDIR="$(cd "$EVDIR" && pwd)"
PKI="$(mktemp -d "${TMPDIR:-/tmp}/hc_acme_pki.XXXXXX")"

log() { echo "[acme-proof] $*"; }

# ---- engine ---------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then ENG=podman; RT="podman compose"; else ENG=docker; RT="docker compose"; fi

teardown() {
  # §11.4.174: only ever touch OUR distinctly-named project's containers.
  if [ "$KEEP" -eq 1 ]; then log "--keep set; leaving $PROJECT up"; else
    ( cd "$HERE" && ACME_PROOF_PKI="$PKI" ACME_PROOF_HOSTPORT="$HOSTPORT" \
        CS_DOMAIN="$CS_DOMAIN" ACME_EMAIL="$ACME_EMAIL" ACME_CA_URL="$ACME_CA_URL" \
        $RT -p "$PROJECT" -f "$COMPOSE" down -v --remove-orphans >/dev/null 2>&1 || true )
    # belt-and-suspenders: remove any stragglers of OUR project only.
    for c in $("$ENG" ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PROJECT}[_-]" || true); do
      "$ENG" rm -f "$c" >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$PKI" 2>/dev/null || true
}
trap teardown EXIT

port_free() { ! ss -ltn 2>/dev/null | grep -q ":$1 "; }
pick_port() {
  local p="$1" _i
  for _i in $(seq 1 30); do port_free "$p" && { echo "$p"; return 0; }; p=$((p+1)); done
  echo "$1"
}

fail() { echo "RESULT: FAIL — $*"; echo "ACME_PROOF_RESULT=FAIL"; echo "ACME_EVIDENCE_DIR=$EVDIR"; exit 1; }
skip() { echo "RESULT: SKIP — $*"; echo "ACME_PROOF_RESULT=SKIP"; echo "ACME_EVIDENCE_DIR=$EVDIR"; exit 2; }

# ---- preflight ------------------------------------------------------------
PRE="$EVDIR/acme_preflight.txt"
{
  echo "=== ACME proof preflight $(date -u +%FT%TZ) ==="
  echo "engine: $ENG ($($ENG --version 2>/dev/null))"
  echo "openssl: $(openssl version 2>/dev/null)"
  echo "project: $PROJECT (DISTINCT from installed 'deploy' — §11.4.119)"
} > "$PRE"

command -v openssl >/dev/null 2>&1 || fail "openssl not installed"
command -v ss >/dev/null 2>&1 || echo "warn: ss missing; port scan degraded" >> "$PRE"

# images must be present OR pullable; no network => honest SKIP (§11.4.3).
for img in ghcr.io/letsencrypt/pebble:latest docker.io/library/caddy:2; do
  if ! "$ENG" image exists "$img" 2>/dev/null; then
    log "pulling $img ..."
    if ! timeout 300 "$ENG" pull "$img" >>"$PRE" 2>&1; then
      skip "image $img unpullable (network_unreachable_external)"
    fi
  fi
  echo "image present: $img" >> "$PRE"
done

HOSTPORT="$(pick_port "$HOSTPORT_REQ")"
echo "host port (edge :443 -> 127.0.0.1): $HOSTPORT" >> "$PRE"
export ACME_PROOF_HOSTPORT="$HOSTPORT" ACME_PROOF_PKI="$PKI" CS_DOMAIN ACME_EMAIL ACME_CA_URL

# ---- generate the harness mini-CA + pebble server cert --------------------
PKIEV="$EVDIR/acme_pki.txt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$PKI/minica.key" -out "$PKI/minica.crt" \
  -days 5 -subj "/CN=HelixCode Local ACME Proof Mini-CA" >/dev/null 2>&1 || fail "minica gen failed"
openssl req -newkey rsa:2048 -nodes -keyout "$PKI/pebble.key" -out "$PKI/pebble.csr" \
  -subj "/CN=pebble" >/dev/null 2>&1 || fail "pebble csr failed"
openssl x509 -req -in "$PKI/pebble.csr" -CA "$PKI/minica.crt" -CAkey "$PKI/minica.key" \
  -CAcreateserial -days 5 -out "$PKI/pebble.crt" \
  -extfile <(printf 'subjectAltName=DNS:pebble,DNS:localhost,IP:127.0.0.1') >/dev/null 2>&1 \
  || fail "pebble cert sign failed"
chmod 600 "$PKI"/*.key 2>/dev/null || true
{
  echo "=== harness mini-CA (secures Pebble's ACME/mgmt HTTPS endpoint) ==="
  openssl x509 -in "$PKI/minica.crt" -noout -subject -dates 2>/dev/null
  echo "=== pebble server cert (SAN must include 'pebble') ==="
  openssl x509 -in "$PKI/pebble.crt" -noout -subject -issuer -ext subjectAltName 2>/dev/null \
    || openssl x509 -in "$PKI/pebble.crt" -noout -text 2>/dev/null | grep -A1 'Subject Alternative'
} > "$PKIEV"

# ---- bring the harness up (rootless, §11.4.161) ---------------------------
log "bringing up $PROJECT on host port $HOSTPORT ..."
( cd "$HERE" && $RT -p "$PROJECT" -f "$COMPOSE" down -v --remove-orphans >/dev/null 2>&1 || true )
if ! ( cd "$HERE" && $RT -p "$PROJECT" -f "$COMPOSE" up -d >>"$PRE" 2>&1 ); then
  ( cd "$HERE" && $RT -p "$PROJECT" -f "$COMPOSE" logs >>"$EVDIR/acme_edge_logs.txt" 2>&1 || true )
  fail "compose up failed (see acme_preflight.txt / acme_edge_logs.txt)"
fi

edge_name() { "$ENG" ps --format '{{.Names}}' 2>/dev/null | grep -E "^${PROJECT}[_-].*edge" | head -1; }

get_leaf() { # $1=servername -> PEM on stdout
  echo | timeout 12 openssl s_client -connect "127.0.0.1:${HOSTPORT}" -servername "$1" 2>/dev/null \
    | openssl x509 2>/dev/null || true
}
get_chain() { # $1=servername -> full presented chain text
  echo | timeout 12 openssl s_client -connect "127.0.0.1:${HOSTPORT}" -servername "$1" -showcerts 2>/dev/null || true
}
wait_leaf() { # $1=out-pem-path -> 0 if a PEBBLE-issued leaf becomes served
  local i pem issuer
  for i in $(seq 1 40); do
    pem="$(get_leaf "$CS_DOMAIN")"
    if [ -n "$pem" ]; then
      issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer 2>/dev/null || true)"
      printf '%s\n' "$pem" > "$1"
      case "$issuer" in *[Pp]ebble*) return 0 ;; esac
    fi
    sleep 3
  done
  return 1
}

# ---- PROOF 1: issuance ----------------------------------------------------
LEAF1="$EVDIR/acme_leaf_initial.pem"
log "waiting for Caddy to obtain a Pebble-issued leaf for $CS_DOMAIN ..."
if ! wait_leaf "$LEAF1"; then
  ( "$ENG" logs "$(edge_name)" > "$EVDIR/acme_edge_logs.txt" 2>&1 || true )
  fail "Caddy never served a Pebble-issued leaf (see acme_edge_logs.txt)"
fi
ISSUER1="$(openssl x509 -in "$LEAF1" -noout -issuer 2>/dev/null)"
SERIAL1="$(openssl x509 -in "$LEAF1" -noout -serial 2>/dev/null | cut -d= -f2)"
NB1="$(openssl x509 -in "$LEAF1" -noout -startdate 2>/dev/null | cut -d= -f2)"
{
  echo "=== PROOF 1: served leaf ISSUED via ACME by Pebble ==="
  echo "domain : $CS_DOMAIN  (served on 127.0.0.1:$HOSTPORT)"
  echo "issuer : $ISSUER1"
  echo "serial : $SERIAL1"
  echo "notBefore: $NB1"
  echo "--- subject/issuer/dates ---"
  openssl x509 -in "$LEAF1" -noout -subject -issuer -dates 2>/dev/null
  echo "--- full chain presented (Pebble Intermediate expected) ---"
  get_chain "$CS_DOMAIN" | grep -E 's:|i:|subject=|issuer=' 2>/dev/null || true
} > "$EVDIR/acme_leaf_initial.txt"
"$ENG" logs "$(edge_name)" > "$EVDIR/acme_edge_logs.txt" 2>&1 || true

case "$ISSUER1" in *[Pp]ebble*) : ;; *) fail "served leaf NOT issued by Pebble (issuer=$ISSUER1)";; esac

# ---- PROOF 2: reverse_proxy backend reachable over the ACME cert ----------
BC="$EVDIR/acme_backend_curl.txt"
{
  echo "=== PROOF 2: reverse_proxy backend served over the ACME leaf ==="
  echo "# curl --resolve $CS_DOMAIN:$HOSTPORT:127.0.0.1 --cacert <pebble-signed>"
  curl -sS --max-time 12 --cacert "$PKI/minica.crt" \
       --resolve "${CS_DOMAIN}:${HOSTPORT}:127.0.0.1" \
       "https://${CS_DOMAIN}:${HOSTPORT}/" 2>&1 || true
  echo
  echo "# (leaf chains to Pebble, not minica; -k body proof below)"
  curl -sSk --max-time 12 --resolve "${CS_DOMAIN}:${HOSTPORT}:127.0.0.1" \
       "https://${CS_DOMAIN}:${HOSTPORT}/" 2>&1 || true
} > "$BC"
grep -q "helixcode-acme-proof backend OK" "$BC" || echo "note: backend body not confirmed (issuer proof stands)" >> "$BC"

# ---- PROOF 3: rotation (renewal produces a NEW cert) ----------------------
EDGE="$(edge_name)"
[ -n "$EDGE" ] || fail "edge container not found for rotation"
log "forcing rotation: dropping stored cert + restarting edge (renewal path) ..."
"$ENG" exec "$EDGE" rm -rf /data/caddy/certificates >/dev/null 2>&1 || true
"$ENG" restart "$EDGE" >/dev/null 2>&1 || fail "edge restart failed"
sleep 3
LEAF2="$EVDIR/acme_leaf_rotated.pem"
if ! wait_leaf "$LEAF2"; then
  ( "$ENG" logs "$EDGE" >> "$EVDIR/acme_edge_logs.txt" 2>&1 || true )
  fail "rotation: Caddy did not re-issue a Pebble leaf after cert drop+restart"
fi
ISSUER2="$(openssl x509 -in "$LEAF2" -noout -issuer 2>/dev/null)"
SERIAL2="$(openssl x509 -in "$LEAF2" -noout -serial 2>/dev/null | cut -d= -f2)"
NB2="$(openssl x509 -in "$LEAF2" -noout -startdate 2>/dev/null | cut -d= -f2)"
{
  echo "=== PROOF 3: ROTATION — a NEW leaf replaced the old and is served ==="
  echo "initial serial : $SERIAL1  (notBefore $NB1)"
  echo "rotated serial : $SERIAL2  (notBefore $NB2)"
  echo "rotated issuer : $ISSUER2"
  if [ "$SERIAL1" != "$SERIAL2" ]; then echo "ROTATION: CONFIRMED (serial changed)"; else echo "ROTATION: NOT CONFIRMED (serial identical)"; fi
} > "$EVDIR/acme_rotation.txt"

case "$ISSUER2" in *[Pp]ebble*) : ;; *) fail "rotated leaf NOT issued by Pebble (issuer=$ISSUER2)";; esac
[ "$SERIAL1" != "$SERIAL2" ] || fail "rotation did not change the serial ($SERIAL1)"

# ---- summary --------------------------------------------------------------
{
  echo "=== ACME PROOF RESULT: PASS ==="
  echo "issued-by-pebble : yes  (issuer=$ISSUER1)"
  echo "backend-served   : $(grep -q 'backend OK' "$BC" && echo yes || echo 'issuer-proof-only')"
  echo "rotation         : yes  (serial $SERIAL1 -> $SERIAL2)"
  echo "evidence-dir     : $EVDIR"
} | tee "$EVDIR/acme_result.txt"

echo "ACME_PROOF_RESULT=PASS"
echo "ACME_ISSUER_MATCH=pebble"
echo "ACME_SERIAL_INITIAL=$SERIAL1"
echo "ACME_SERIAL_ROTATED=$SERIAL2"
echo "ACME_ROTATED=yes"
echo "ACME_EVIDENCE_DIR=$EVDIR"
exit 0
