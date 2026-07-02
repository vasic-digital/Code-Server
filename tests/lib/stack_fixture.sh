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
# Two topologies are supported side-by-side (§11.4.6, no guessing which is live):
#   LEGACY  — containerized code-server behind Caddy, PASSWORD login (helpers
#             hc_stack_up / hc_login_* / hc_cs_exec, unchanged below).
#   AUTH-PIVOT (2026-07-01) — Caddy TLS edge (deploy_caddy_1 :52443) -> forward_auth
#             -> host-native gate `helix-auth` (127.0.0.1:8081) -> reverse_proxy
#             -> host-native code-server (127.0.0.1:8080, --auth none). Login is
#             SSH-KEY challenge-response (no password). New helpers (hc_new_stack_up
#             / hc_sshkey_* / hc_scrape_hidden_inputs / hc_extract_challenge) live
#             in the ADDITIVE section at the bottom of this file.
#
# Purpose      : resolve stack endpoints/creds + boot/login/exec + ssh-key login
# Inputs       : deploy/.env (PORT_PREFIX, CODE_SERVER_PASSWORD, PROJECTS) ;
#                HELIX_AUTH_ADDR HELIX_CODESERVER_ADDR HELIX_AUTH_NAMESPACE (opt)
# Outputs      : env vars HC_HTTPS/HC_HTTP/HC_BASE/HC_ENGINE/HC_CS/HC_CADDY +
#                HC_GATE_ADDR/HC_CSVR_ADDR/HC_NEW_STACK_DETAIL + HC_SSHKEY_* results
# Side-effects : hc_stack_up may start containers; helpers never delete data;
#                ssh-key helpers create throwaway keys under mktemp dirs only
# Dependencies : bash, curl, podman|docker ; openssl (TLS) ; ssh-keygen (auth pivot)
# Cross-refs    : §11.4.76 §11.4.119 §11.4.10 §11.4.6 §11.4.69 §11.4.98 §11.4.111 ;
#                harness.sh ; scripts/start.sh ; specs 2026-07-01-auth-pivot-ssh-key.md
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

# ==========================================================================
# AUTH-PIVOT topology helpers (2026-07-01 §11.4.169 ssh-key auth suites).
#
#   Browser --HTTPS :52443--> Caddy (deploy_caddy_1)
#       -> forward_auth --> host-native gate `helix-auth` (127.0.0.1:8081)
#            GET  /login  : challenge page (nonce + `ssh-keygen -Y sign` command
#                           + hidden form fields) ; NO password field
#            POST /login  : {scraped hidden fields, signature} -> 303 + session cookie
#            GET  /auth   : 200 with a valid cookie else 401 (gate fails CLOSED)
#       -> reverse_proxy --> host-native code-server (127.0.0.1:8080, --auth none)
#
# ADDITIVE — the password-era helpers above stay intact for the legacy suites.
# RESILIENCE (§11.4.6): the gate's FINAL hidden-field names AND session-cookie
# name are treated as UNKNOWN/variable — every hidden <input> is scraped
# generically, the signed nonce is read from the rendered `printf %s | ssh-keygen`
# command (the exact bytes a real user signs), and the session cookie is captured
# via a jar (its name, incl. any `__Host-` prefix, is never hardcoded).
# --------------------------------------------------------------------------

# host-native endpoints — config-injected, decoupled (§11.4.28); safe defaults.
HC_GATE_ADDR="${HELIX_AUTH_ADDR:-127.0.0.1:8081}"
HC_CSVR_ADDR="${HELIX_CODESERVER_ADDR:-127.0.0.1:8080}"
HC_SIGN_NAMESPACE="${HELIX_AUTH_NAMESPACE:-helixcode-login}"
export HC_GATE_ADDR HC_CSVR_ADDR HC_SIGN_NAMESPACE

# hc_http_code <url> -> HTTP status, EXACTLY 3 digits (000 on failure). `-k` makes
# it usable for the self-signed HTTPS edge too. curl's own `-w '%{http_code}'`
# already prints 000 on connection failure, so we must NOT also `|| echo 000`
# (that yields "000000" and breaks a `!= 000` comparison).
hc_http_code() { local c; c="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null)"; printf '%s' "${c:-000}"; }

# hc_new_stack_up: probe the auth-pivot stack (gate /healthz + Caddy edge +
# code-server). Returns 0 iff the gate answers /healthz=200 AND the Caddy edge is
# reachable; sets HC_NEW_STACK_DETAIL for evidence. Suites guard on this and
# ab_skip_with_reason(topology_unsupported) when it is down — the stack is
# deployed LIVE by the conductor later, never faked green (§11.4 / §11.4.69).
hc_new_stack_up() {
  hc_load_env
  local gate cad cs
  gate="$(hc_http_code "http://${HC_GATE_ADDR}/healthz")"
  cad="$(hc_http_code "${HC_BASE}/")"
  cs="$(hc_http_code "http://${HC_CSVR_ADDR}/")"
  HC_NEW_STACK_DETAIL="gate(${HC_GATE_ADDR}/healthz)=${gate} caddy(${HC_BASE}/)=${cad} codeserver(${HC_CSVR_ADDR}/)=${cs}"
  export HC_NEW_STACK_DETAIL
  [ "$gate" = 200 ] && [ "$cad" != 000 ]
}

# hc_legacy_model_retired -> 0 (true) iff the RETIRED containerized code-server +
# CODE_SERVER_PASSWORD login model is gone, i.e. this host now runs the 2026-07-01
# host-native SSH-key auth-pivot stack (docs/superpowers/specs/2026-07-01-auth-pivot-
# ssh-key.md). The pre-release suites (integration/e2e/security/tls_letsencrypt/
# full_automation/concurrency/memory/benchmark/helixqa/challenges) validate that old
# model and are superseded by the *_auth suites; on the new stack they would
# FALSE-FAIL (§11.4.1), so they SKIP-with-reason instead (§11.4.90 superseded).
# Detection is evidence-based (§11.4.6, no guessing) — EITHER signal proves
# retirement: (a) the old containerized code-server ($HC_CS) is ABSENT, OR (b)
# deploy/.env carries NO CODE_SERVER_PASSWORD (password login retired). On the OLD
# stack (old container present AND password set) it returns 1 (false) so those
# suites still run unchanged. Read-only; never mutates the stack.
hc_legacy_model_retired() {
  hc_load_env
  local cs_present=0
  "$HC_ENGINE" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$HC_CS" && cs_present=1
  [ "$cs_present" = 0 ] && return 0          # old code-server container gone -> retired
  [ -z "${HC_PASSWORD:-}" ] && return 0      # password login gone -> retired
  return 1                                    # old container present AND password set
}

# ---- generic HTML form scraping (no field-name assumptions §11.4.6) -------

# _hc_attr <input-tag> <attr-name> -> attribute value (double / single / unquoted).
# Requires whitespace before the attr name so `name` never matches `data-name`.
_hc_attr() {
  local tag="$1" a="$2" v
  v="$(printf '%s' "$tag" | grep -oiE "[[:space:]]${a}[[:space:]]*=[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E 's/^[^"]*"//; s/"$//')"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(printf '%s' "$tag" | grep -oiE "[[:space:]]${a}[[:space:]]*=[[:space:]]*'[^']*'" | head -n1 | sed -E "s/^[^']*'//; s/'\$//")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(printf '%s' "$tag" | grep -oiE "[[:space:]]${a}[[:space:]]*=[[:space:]]*[^ >\"']+" | head -n1 | sed -E 's/^[[:space:]]*[^=]+=[[:space:]]*//')"
  printf '%s' "$v"
}

# hc_scrape_hidden_inputs <html_file> -> one `name=value` line per <input type=hidden>.
# Robust to attribute order, single/double/unquoted quoting, and extra/renamed fields.
hc_scrape_hidden_inputs() {
  local f="$1" q="[\"']" tag nm vl
  tr '\n' ' ' < "$f" 2>/dev/null | sed -E 's/</\n</g' \
    | grep -iE "<input[[:space:]][^>]*type[[:space:]]*=[[:space:]]*${q}?hidden" \
    | while IFS= read -r tag; do
        tag="${tag%%>*}"
        nm="$(_hc_attr "$tag" name)"
        [ -n "$nm" ] || continue
        vl="$(_hc_attr "$tag" value)"
        printf '%s=%s\n' "$nm" "$vl"
      done
}

# hc_extract_challenge <html_file> -> the nonce the user is told to sign.
# Authoritative source = the exact `printf %s '<nonce>' | ssh-keygen -Y sign`
# command rendered on the page (single/double/entity-quoted, or unquoted); falls
# back to a hidden field literally named challenge/nonce/challenge_nonce.
hc_extract_challenge() {
  local f="$1" nonce="" one
  one="$(tr '\n' ' ' < "$f" 2>/dev/null)"
  # Most robust: the nonce is the first '|'-field of the challenge_token hidden
  # input — always present, fixed structure, and immune to the HTML entity-encoding
  # of the printf quotes (&#39;) that defeats the command-scrape fallbacks below.
  nonce="$(hc_scrape_hidden_inputs "$f" | sed -nE 's/^challenge_token=([^|]+)[|].*/\1/p' | head -n1)"
  [ -n "$nonce" ] || nonce="$(printf '%s' "$one" | sed -nE "s/.*printf[[:space:]]+%s[[:space:]]+'([^']+)'[[:space:]]*[|].*/\1/p" | head -n1)"
  [ -n "$nonce" ] || nonce="$(printf '%s' "$one" | sed -nE 's/.*printf[[:space:]]+%s[[:space:]]+"([^"]+)"[[:space:]]*[|].*/\1/p' | head -n1)"
  [ -n "$nonce" ] || nonce="$(printf '%s' "$one" | sed -nE 's#.*printf[[:space:]]+%s[^A-Za-z0-9+/=_-]*([A-Za-z0-9+/=_-]{12,})[^A-Za-z0-9+/=_-].*ssh-keygen[[:space:]]+-Y[[:space:]]+sign.*#\1#p' | head -n1)"
  [ -n "$nonce" ] || nonce="$(hc_scrape_hidden_inputs "$f" | sed -nE 's/^(challenge|nonce|challenge_nonce)=(.+)$/\2/Ip' | head -n1)"
  printf '%s' "$nonce"
}

# ---- session-cookie jar helpers ------------------------------------------
# hc_jar_names <jar> -> the cookie NAME column (handles curl's #HttpOnly_ prefix
# and Netscape 7-column format; name is column 6). Names may be `__Host-`-prefixed.
hc_jar_names() { awk '/^#HttpOnly_/{print $6; next} /^#/{next} NF{print $6}' "${1:-/dev/null}" 2>/dev/null; }

# ---- ssh-key challenge-response login ------------------------------------

# hc_sshkey_keygen <dir> -> generate a throwaway ed25519 keypair; prints privkey path.
hc_sshkey_keygen() {
  local d="${1:?dir}"
  ssh-keygen -q -t ed25519 -N '' -C 'helixcode-test' -f "$d/id_ed25519" </dev/null >/dev/null 2>&1 || return 1
  printf '%s\n' "$d/id_ed25519"
}

# hc_allowed_signers <pubkey_file> <principal> <out_file>
hc_allowed_signers() { printf '%s %s\n' "$2" "$(cat "$1")" > "$3"; }

# hc_sshkey_challenge <base> <jar> <out_html>: GET <base>/login with a SHARED jar
# (captures any CSRF / pre-session cookie), scrape the nonce + every hidden field.
# Sets HC_SSHKEY_NONCE, HC_SSHKEY_HIDDEN (name=value lines), HC_SSHKEY_FIELDS
# (space-separated names). Returns 0 iff a challenge nonce was found.
hc_sshkey_challenge() {
  local base="$1" jar="$2" page="$3"
  HC_SSHKEY_NONCE=""; HC_SSHKEY_HIDDEN=""; HC_SSHKEY_FIELDS=""
  curl -k -s -c "$jar" -b "$jar" --max-time 15 "$base/login" -o "$page" 2>/dev/null || return 1
  HC_SSHKEY_NONCE="$(hc_extract_challenge "$page")"
  HC_SSHKEY_HIDDEN="$(hc_scrape_hidden_inputs "$page")"
  HC_SSHKEY_FIELDS="$(printf '%s\n' "$HC_SSHKEY_HIDDEN" | sed -nE 's/^([^=]+)=.*/\1/p' | tr '\n' ' ')"
  export HC_SSHKEY_NONCE HC_SSHKEY_HIDDEN HC_SSHKEY_FIELDS
  [ -n "$HC_SSHKEY_NONCE" ]
}

# hc_sshkey_submit <base> <jar> <signature_value> [principal] [header_dump_file]:
# POST every scraped hidden field (from HC_SSHKEY_HIDDEN) with `signature`
# overridden to the given value — appended if the form had no signature field, so
# the gate's final field set does not matter. Sets HC_SSHKEY_CODE, HC_SSHKEY_COOKIE
# (a cookie name now in the jar) and HC_SSHKEY_NEWCOOKIE (a cookie that appeared as
# a RESULT of the POST — distinguishes the session cookie from a pre-existing CSRF
# cookie, avoiding a false PASS). Returns 0 iff a NEW cookie appeared AND POST was
# a 302/303 redirect (the spec's success shape; a bad login is 401 -> returns 1).
hc_sshkey_submit() {
  local base="$1" jar="$2" sigval="$3" principal="${4:-}" hdr="${5:-/dev/null}"
  : "${HC_SSHKEY_HIDDEN:=}"
  HC_SSHKEY_CODE=000; HC_SSHKEY_COOKIE=""; HC_SSHKEY_NEWCOOKIE=""
  local pre; pre="$(hc_jar_names "$jar" | sort -u)"
  local -a args=(); local had_sig=0 line name val
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"; val="${line#*=}"
    if [ "$name" = signature ]; then val="$sigval"; had_sig=1; fi
    if [ -n "$principal" ] && [ "$name" = principal ]; then val="$principal"; fi
    args+=(--data-urlencode "$name=$val")
  done <<EOF
$HC_SSHKEY_HIDDEN
EOF
  [ "$had_sig" = 1 ] || args+=(--data-urlencode "signature=$sigval")
  if [ -n "$principal" ] && ! printf '%s\n' "$HC_SSHKEY_HIDDEN" | grep -q '^principal='; then
    args+=(--data-urlencode "principal=$principal")
  fi
  HC_SSHKEY_CODE="$(curl -k -s -c "$jar" -b "$jar" -D "$hdr" -o /dev/null -w '%{http_code}' \
    --max-time 20 "${args[@]}" "$base/login" 2>/dev/null || echo 000)"
  local post; post="$(hc_jar_names "$jar" | sort -u)"
  HC_SSHKEY_NEWCOOKIE="$(comm -13 <(printf '%s\n' "$pre") <(printf '%s\n' "$post") 2>/dev/null | grep -m1 . || true)"
  HC_SSHKEY_COOKIE="$(printf '%s\n' "$post" | grep -m1 . || true)"
  export HC_SSHKEY_CODE HC_SSHKEY_COOKIE HC_SSHKEY_NEWCOOKIE
  [ -n "$HC_SSHKEY_NEWCOOKIE" ] && { [ "$HC_SSHKEY_CODE" = 302 ] || [ "$HC_SSHKEY_CODE" = 303 ]; }
}

# hc_sshkey_login <base_url> <private_key_file> <cookiejar_out> [principal]:
# End-to-end resilient login — GET challenge -> sign the nonce with <key>
# (`printf %s "$nonce" | ssh-keygen -Y sign -n <ns> -f <key>`, armored) -> POST all
# scraped hidden fields + signature -> returns 0 iff a session cookie was set.
# On return, HC_SSHKEY_{NONCE,FIELDS,CODE,COOKIE,NEWCOOKIE} describe the outcome
# for evidence (no secret is ever exposed — only the nonce, field names, code).
hc_sshkey_login() {
  local base="${1:?base_url}" key="${2:?private key file}" jar="${3:?cookiejar out}" principal="${4:-}"
  : > "$jar"
  local page; page="$(mktemp "${TMPDIR:-/tmp}/hc_login_page.XXXXXX")"
  if ! hc_sshkey_challenge "$base" "$jar" "$page"; then rm -f "$page"; return 1; fi
  local sig; sig="$(printf %s "$HC_SSHKEY_NONCE" | ssh-keygen -Y sign -n "$HC_SIGN_NAMESPACE" -f "$key" 2>/dev/null)"
  rm -f "$page"
  printf '%s' "$sig" | grep -q 'BEGIN SSH SIGNATURE' || return 1
  hc_sshkey_submit "$base" "$jar" "$sig" "$principal"
}

# hc_sshkey_sign_smoke <evidence_path> [principal]: SELF-CONTAINED proof of the
# challenge-response CRYPTO (needs NO stack) — generate an ed25519 key, sign a
# fresh nonce via the SAME `ssh-keygen -Y sign` path hc_sshkey_login uses, assert
# an armored `-----BEGIN SSH SIGNATURE-----` is produced AND `ssh-keygen -Y verify`
# ACCEPTS it against an allowed_signers built from the pubkey, AND a WRONG nonce is
# REJECTED. Writes evidence to <path>. Returns 0 pass / 1 fail / 2 ssh-keygen absent.
hc_sshkey_sign_smoke() {
  local ev="${1:?evidence}" principal="${2:-milosvasic}"
  command -v ssh-keygen >/dev/null 2>&1 || return 2
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/hc_sign_smoke.XXXXXX")"
  local key sig="$d/nonce.sig" as="$d/allowed_signers"
  local nonce="smoke-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)-$RANDOM$RANDOM"
  if ! key="$(hc_sshkey_keygen "$d")"; then rm -rf "$d"; return 1; fi
  printf %s "$nonce" | ssh-keygen -Y sign -n "$HC_SIGN_NAMESPACE" -f "$key" > "$sig" 2>/dev/null
  hc_allowed_signers "$key.pub" "$principal" "$as"
  local armored=0 verified=0 wrong_rejected=0
  grep -q 'BEGIN SSH SIGNATURE' "$sig" 2>/dev/null && armored=1
  if printf %s "$nonce" | ssh-keygen -Y verify -f "$as" -I "$principal" -n "$HC_SIGN_NAMESPACE" -s "$sig" >/dev/null 2>&1; then verified=1; fi
  if ! printf %s "WRONG-$nonce" | ssh-keygen -Y verify -f "$as" -I "$principal" -n "$HC_SIGN_NAMESPACE" -s "$sig" >/dev/null 2>&1; then wrong_rejected=1; fi
  { echo "=== ssh-key challenge-response sign/verify smoke (self-contained, no stack) ==="
    echo "namespace             : $HC_SIGN_NAMESPACE"
    echo "principal             : $principal"
    echo "nonce                 : $nonce"
    echo "armored signature     : $([ "$armored" = 1 ] && echo yes || echo NO)   (expect: -----BEGIN SSH SIGNATURE-----)"
    echo "signature first line  : $(head -n1 "$sig" 2>/dev/null)"
    echo "signature bytes       : $(wc -c < "$sig" 2>/dev/null | tr -d ' ')"
    echo "key fingerprint       : $(ssh-keygen -l -f "$key.pub" 2>/dev/null)"
    echo "verify(correct nonce) : $([ "$verified" = 1 ] && echo ACCEPTED || echo REJECTED)   (expect ACCEPTED)"
    echo "verify(wrong  nonce)  : $([ "$wrong_rejected" = 1 ] && echo REJECTED || echo ACCEPTED)   (expect REJECTED)"
  } > "$ev"
  rm -rf "$d"
  [ "$armored" = 1 ] && [ "$verified" = 1 ] && [ "$wrong_rejected" = 1 ]
}

# ---- throwaway ISOLATED helix-auth gate (non-destructive C3 chaos, §11.4.85) --
# A fully isolated helix-auth instance on its OWN loopback port with a THROWAWAY
# ed25519 keypair / authorized_keys / cookie_secret — so a destructive
# cookie-secret rotation test never touches the LIVE gate (rotating the live
# secret would log the operator's session out, §11.4.101). Needs `go` (to build
# the gate from source) + `ssh-keygen`. Uses NO real credential (the throwaway
# gate trusts only its own throwaway key), so it runs fully autonomously.

# hc_build_auth_gate <out>: `go build` the auth gate -> <out>. Builds from
# $HC_AUTH_GATE_SRC when set (a §1.1 paired-mutation seam that lets a meta-test
# build a deliberately-broken gate and prove C3 FAILs on it), else the tracked
# services/auth_gate. 0 built · 2 go toolchain absent · 1 build failed.
hc_build_auth_gate() {
  local out="${1:?out}"
  local src="${HC_AUTH_GATE_SRC:-$HC_ROOT/services/auth_gate}"
  command -v go >/dev/null 2>&1 || return 2
  ( cd "$src" && GOFLAGS=-mod=mod go build -o "$out" . ) >/dev/null 2>&1 || return 1
  [ -x "$out" ]
}

# hc_tg_pick_port [base]: echo the first free loopback TCP port at/after base.
hc_tg_pick_port() {
  local p="${1:-52560}" i=0
  while [ "$i" -lt 40 ]; do
    if ! { ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null; } | grep -qE ":${p}( |$)"; then
      echo "$p"; return 0
    fi
    p=$((p+1)); i=$((i+1))
  done
  echo "$p"
}

# _hc_tg_launch: (re)launch the gate process with the stored HC_TG_* config. The
# gate loads its cookie secret from HC_TG_SECRET at STARTUP (main.go), so a
# relaunch after rotating that file makes the gate adopt the new secret.
_hc_tg_launch() {
  HELIX_AUTH_MODE=sshkey HELIX_AUTH_BIND="127.0.0.1:$HC_TG_PORT" \
    HELIX_AUTH_COOKIE_SECRET="$HC_TG_SECRET" \
    HELIX_AUTH_AUTHORIZED_KEYS="$HC_TG_DIR/authorized_keys" \
    HELIX_AUTH_ACCOUNT="$HC_TG_PRINCIPAL" HELIX_AUTH_PRINCIPAL="$HC_TG_PRINCIPAL" \
    "$HC_TG_BIN" >"$HC_TG_DIR/gate.log" 2>&1 &
  HC_TG_PID=$!
}

# _hc_tg_wait_ready: poll /healthz until 200 (~12s) or the process dies. 0/1.
_hc_tg_wait_ready() {
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HC_TG_BASE/healthz" 2>/dev/null)" = 200 ] && return 0
    kill -0 "$HC_TG_PID" 2>/dev/null || return 1
    sleep 0.2; i=$((i+1))
  done
  return 1
}

# hc_spawn_throwaway_gate <workdir> [principal] [base_port]: build + launch an
# isolated gate with a throwaway keypair. Sets HC_TG_{DIR,BIN,PORT,BASE,KEY,
# SECRET,PRINCIPAL,PID}. 0 ready · 2 go/ssh-keygen absent (caller SKIPs topology)
# · 1 build/launch failure. The caller MUST arrange hc_stop_throwaway_gate on
# every exit path (§11.4.14).
hc_spawn_throwaway_gate() {
  local wd="${1:?workdir}" principal="${2:-milosvasic}" baseport="${3:-52560}"
  command -v ssh-keygen >/dev/null 2>&1 || return 2
  HC_TG_DIR="$(mktemp -d "$wd/hc_tg.XXXXXX")" || return 1
  HC_TG_BIN="$HC_TG_DIR/helix-auth"
  hc_build_auth_gate "$HC_TG_BIN"; local b=$?; [ "$b" -eq 0 ] || { rm -rf "$HC_TG_DIR"; HC_TG_DIR=""; return "$b"; }
  ssh-keygen -q -t ed25519 -N '' -C 'hc-throwaway-gate' -f "$HC_TG_DIR/key" </dev/null >/dev/null 2>&1 || return 1
  cp -f "$HC_TG_DIR/key.pub" "$HC_TG_DIR/authorized_keys" || return 1
  HC_TG_KEY="$HC_TG_DIR/key"; HC_TG_SECRET="$HC_TG_DIR/cookie_secret"; HC_TG_PRINCIPAL="$principal"
  HC_TG_PORT="$(hc_tg_pick_port "$baseport")"; HC_TG_BASE="http://127.0.0.1:$HC_TG_PORT"
  _hc_tg_launch
  _hc_tg_wait_ready || return 1
  export HC_TG_DIR HC_TG_BIN HC_TG_PORT HC_TG_BASE HC_TG_KEY HC_TG_SECRET HC_TG_PRINCIPAL HC_TG_PID
  return 0
}

# hc_restart_throwaway_gate: kill + relaunch so the gate reloads its (possibly
# rotated) cookie secret from disk. 0 ready / 1 not.
hc_restart_throwaway_gate() {
  [ -n "${HC_TG_PID:-}" ] && { kill "$HC_TG_PID" 2>/dev/null; wait "$HC_TG_PID" 2>/dev/null; }
  _hc_tg_launch
  _hc_tg_wait_ready
}

# hc_stop_throwaway_gate: terminate + reap + remove the throwaway dir (idempotent).
hc_stop_throwaway_gate() {
  [ -n "${HC_TG_PID:-}" ] && { kill "$HC_TG_PID" 2>/dev/null; wait "$HC_TG_PID" 2>/dev/null; HC_TG_PID=""; }
  [ -n "${HC_TG_DIR:-}" ] && [ -d "$HC_TG_DIR" ] && rm -rf "$HC_TG_DIR"
  HC_TG_DIR=""
}
