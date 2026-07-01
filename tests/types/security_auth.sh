#!/usr/bin/env bash
#
# tests/types/security_auth.sh — ANTI-BLUFF security suite for the SSH-KEY auth gate.
#
# The 2026-07-01 auth pivot (docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md)
# routes: Caddy TLS edge (:52443) -> forward_auth -> host-native gate `helix-auth`
# (127.0.0.1:8081) -> reverse_proxy -> host-native code-server (127.0.0.1:8080).
# This suite proves the gate's security posture with REAL captured evidence
# (§11.4 / §11.4.69). No secret is ever printed or written to evidence (§11.4.10).
#
# Assertions:
#   (1) FAIL CLOSED — the gate's forward-auth check denies by DEFAULT: GET /auth
#       with NO cookie -> 401, and with a FORGED cookie -> 401 (never fail-open);
#       an unauthenticated request through the edge is denied, not served. The
#       ACTIVE gate-down chaos ("kill helix-auth -> Caddy denies") is a
#       stress_chaos concern (destructive) — this non-destructive suite proves the
#       observable default-deny contract (§11.4.6, no faked kill).
#   (2) COOKIE FLAGS — the session cookie carries HttpOnly + Secure + SameSite.
#       Needs a valid login (authorized key) -> uses $HELIX_TEST_SSH_KEY when
#       provided, else SKIP-with-reason(credential_absent) — never faked.
#   (3) NO SECRET IN SERVED PAGES — /login has NO password input, NO hidden
#       `password` field, NO private-key material, and shows the ssh-keygen sign
#       command instead (auth is key-based; nothing secret is served).
#   (4) RATE-LIMITED LOGIN — a burst of bad POST /login attempts is throttled
#       (a 429, a Retry-After, dropped/timed-out attempts, or a sharp latency rise).
#   (5) TLS ENFORCED — plain HTTP :52080 is 301/308-redirected to HTTPS.
#
# ANTI-BLUFF (§11.4 / §11.4.1 / §11.4.69): every assertion here requires the live
# auth-pivot stack; when it is not deployed the suite SKIPs-with-reason
# (topology_unsupported) — never a fake PASS. Real green happens at the conductor's
# live-validation step (§11.4.40). Mocks are FORBIDDEN (security type, §11.4.27).
#
# §1.1 PAIRED-MUTATION intent (proves these are not bluff gates):
#   (1) make the gate answer /auth=200 with no cookie (fail-open) -> assertion FAILs.
#   (2) drop SameSite/Secure/HttpOnly from the Set-Cookie -> assertion FAILs.
#   (3) re-introduce a password <input> on /login -> assertion FAILs.
#   (4) disable the rate-limiter -> the burst shows no throttle -> assertion FAILs.
#   (5) change the Caddy :80 `redir` to `reverse_proxy` -> HTTP serves 200 -> FAILs.
#
# Usage:        bash tests/types/security_auth.sh
# Outputs:      qa-results/tests/security_auth/<run-id>/*.txt ; exit 0 iff all PASS/SKIP
# Side-effects: read-only + login probes; NEVER mutates the stack or the git tree
# Dependencies: bash, curl, ssh-keygen ; coreutils, awk
# Cross-refs:   §11.4.10 §11.4.69 §11.4.6 §11.4.107 §11.4.161 ; harness.sh stack_fixture.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init security_auth

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_sec_auth.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"

if ! h_require curl; then
  ab_skip_with_reason "security_auth: curl not on PATH" topology_unsupported
  h_summary; exit $?
fi
if ! hc_new_stack_up; then
  ev="$(h_ev stack_down)"
  { echo "auth-pivot ssh-key stack not deployed (conductor deploys it live later)";
    echo "probe: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "security_auth: ssh-key auth stack not deployed ($HC_NEW_STACK_DETAIL)" topology_unsupported
  h_summary; exit $?
fi

# ---- header helpers ------------------------------------------------------
_hdr_code() { awk 'toupper($1)~/^HTTP/{c=$2} END{print c+0}' "$1" 2>/dev/null; }
_hdr_loc()  { grep -i '^location:' "$1" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}'; }

# =========================================================================
h_head "(1) FAIL CLOSED — gate /auth default-deny (no cookie & forged cookie -> 401)"
ev="$(h_ev fail_closed)"
no_hdr="$WORK/auth_nocookie.hdr"; forged_hdr="$WORK/auth_forged.hdr"; edge_hdr="$WORK/edge_unauth.hdr"
curl -s -D "$no_hdr" -o /dev/null --max-time 10 "http://${HC_GATE_ADDR}/auth" 2>/dev/null || true
curl -s -D "$forged_hdr" -o /dev/null --max-time 10 -H 'Cookie: session=forged-not-a-valid-session' "http://${HC_GATE_ADDR}/auth" 2>/dev/null || true
curl -k -s -D "$edge_hdr" -o /dev/null --max-time 10 "$HC_BASE/" 2>/dev/null || true
nc_code="$(_hdr_code "$no_hdr")"; fc_code="$(_hdr_code "$forged_hdr")"
edge_code="$(_hdr_code "$edge_hdr")"; edge_loc="$(_hdr_loc "$edge_hdr")"
edge_denied=0
{ [ "$edge_code" = 401 ] || [ "$edge_code" = 302 ] || [ "$edge_code" = 303 ] || [ "$edge_code" = 307 ]; } && edge_denied=1
{ echo "assert: the gate denies by DEFAULT (fail-closed) and the edge does not serve unauth requests";
  echo "gate /auth (no cookie)     -> http_code=$nc_code (want 401)";
  echo "gate /auth (forged cookie) -> http_code=$fc_code (want 401)";
  echo "edge GET / (unauth)        -> http_code=$edge_code loc=${edge_loc:-<none>} denied=$edge_denied (want denied=1)"; } > "$ev"
if [ "$nc_code" = 401 ] && [ "$fc_code" = 401 ] && [ "$edge_denied" = 1 ]; then
  ab_pass_with_evidence "FAIL CLOSED: gate /auth=401 without/with-forged cookie; edge denies unauth (code=$edge_code)" "$ev"
else
  ab_fail "FAIL CLOSED violated (no-cookie=$nc_code forged=$fc_code edge=$edge_code denied=$edge_denied — want 401/401/denied) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
h_head "(2) COOKIE FLAGS — session cookie is HttpOnly + Secure + SameSite"
ev="$(h_ev cookie_flags)"
KEYFILE="${HELIX_TEST_SSH_KEY:-}"
if ! h_require ssh-keygen; then
  { echo "ssh-keygen not on PATH — cannot perform a valid login to inspect the session cookie"; } > "$ev"
  ab_skip_with_reason "COOKIE FLAGS: ssh-keygen not on PATH" topology_unsupported
elif [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ]; then
  JAR="$WORK/jar2"; page="$WORK/login2.html"; hdr="$WORK/login2.hdr"; : > "$JAR"
  if hc_sshkey_challenge "$HC_BASE" "$JAR" "$page"; then
    sig="$(printf %s "$HC_SSHKEY_NONCE" | ssh-keygen -Y sign -n "$HC_SIGN_NAMESPACE" -f "$KEYFILE" 2>/dev/null)"
    hc_sshkey_submit "$HC_BASE" "$JAR" "$sig" "$PRINCIPAL" "$hdr" || true
    # Set-Cookie attributes (value redacted; §11.4.10). Also cross-check the jar.
    sc="$(grep -i '^set-cookie:' "$hdr" 2>/dev/null | sed -E 's/(set-cookie: *[^=]+=)[^;]+/\1<redacted>/I')"
    httponly=0; secure=0; samesite=0
    printf '%s' "$sc" | grep -qi 'httponly'   && httponly=1
    printf '%s' "$sc" | grep -qi 'secure'     && secure=1
    printf '%s' "$sc" | grep -qi 'samesite'   && samesite=1
    jar_secure="$(awk '/^#HttpOnly_/{next} /^#/{next} NF{print $4}' "$JAR" 2>/dev/null | grep -m1 . )"
    { echo "assert: the issued session cookie carries HttpOnly, Secure and SameSite";
      echo "POST /login code            : $HC_SSHKEY_CODE";
      echo "Set-Cookie (value redacted) : ${sc:-<none>}";
      echo "HttpOnly=$httponly Secure=$secure SameSite=$samesite (each want 1)";
      echo "jar secure-column (cross-check): ${jar_secure:-<none>}"; } > "$ev"
    if [ "$httponly" = 1 ] && [ "$secure" = 1 ] && [ "$samesite" = 1 ]; then
      ab_pass_with_evidence "COOKIE FLAGS: session Set-Cookie has HttpOnly + Secure + SameSite" "$ev"
    else
      ab_fail "COOKIE FLAGS: missing attribute (HttpOnly=$httponly Secure=$secure SameSite=$samesite) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    { echo "could not obtain a login challenge from $HC_BASE/login"; } > "$ev"
    ab_fail "COOKIE FLAGS: no login challenge to drive a valid login [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "no authorized test key (HELIX_TEST_SSH_KEY unset/unreadable) — cannot mint a session cookie";
    echo "the cookie-flags assertion binds once the conductor provides an authorized key (§11.4.98);";
    echo "SKIP-with-reason, never a faked PASS (§11.4/§11.4.69)."; } > "$ev"
  ab_skip_with_reason "COOKIE FLAGS: no authorized test key (HELIX_TEST_SSH_KEY) to mint a session cookie" credential_absent
fi

# =========================================================================
h_head "(3) NO SECRET IN SERVED PAGES — no password field / no key material on /login"
ev="$(h_ev no_secret_pages)"; page="$WORK/login3.html"
curl -k -s --max-time 15 "$HC_BASE/login" -o "$page" 2>/dev/null || true
has_pw=0;        grep -qiE "<input[^>]*type[[:space:]]*=[[:space:]]*[\"']?password" "$page" 2>/dev/null && has_pw=1
has_pwhidden=0;  hc_scrape_hidden_inputs "$page" | grep -qiE '^password=' && has_pwhidden=1
has_privkey=0;   grep -qiE 'PRIVATE KEY|BEGIN OPENSSH PRIVATE' "$page" 2>/dev/null && has_privkey=1
has_pwtoken=0;   grep -qiE 'CODE_SERVER_PASSWORD|HELIX_AUTH_PASSWORD' "$page" 2>/dev/null && has_pwtoken=1
has_signcmd=0;   grep -qiE 'ssh-keygen[[:space:]]+-Y[[:space:]]+sign' "$page" 2>/dev/null && has_signcmd=1
{ echo "assert: /login serves NO password field and NO key/secret material; it is ssh-key based";
  echo "password <input>                 : $([ $has_pw = 1 ] && echo yes || echo no) (want no)";
  echo "hidden field literally 'password' : $([ $has_pwhidden = 1 ] && echo yes || echo no) (want no)";
  echo "private-key material in page      : $([ $has_privkey = 1 ] && echo yes || echo no) (want no)";
  echo "password env-var token in page    : $([ $has_pwtoken = 1 ] && echo yes || echo no) (want no)";
  echo "shows ssh-keygen sign command     : $([ $has_signcmd = 1 ] && echo yes || echo no) (want yes)"; } > "$ev"
if [ $has_pw = 0 ] && [ $has_pwhidden = 0 ] && [ $has_privkey = 0 ] && [ $has_pwtoken = 0 ] && [ $has_signcmd = 1 ]; then
  ab_pass_with_evidence "NO SECRET IN SERVED PAGES: /login is ssh-key based, no password/key material served" "$ev"
else
  ab_fail "served page leaks/serves a secret or password surface (pw_input=$has_pw pw_hidden=$has_pwhidden privkey=$has_privkey pw_token=$has_pwtoken signcmd=$has_signcmd) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
h_head "(4) RATE-LIMITED LOGIN — burst of GENUINE bad-signature logins throttled (real 429)"
ev="$(h_ev rate_limited)"; BURST="${HC_RL_BURST:-8}"
key="${HELIX_TEST_SSH_KEY:-}"
# The rate-limiter (post-DoS-fix, §11.4.134) counts ONLY genuine post-CSRF+challenge
# SIGNATURE failures — an unauthenticated / wrong-principal / garbage-body flood is
# deliberately NOT rate-counted (that is the fix: it must not let an attacker lock
# out the sole user). So to exercise the limiter we must send REAL bad-sig logins:
# valid CSRF + a FRESH challenge each + an armored-but-WRONG SSH signature. Requires
# a signing key; without one, SKIP (never a fake pass, §11.4.1/§11.4.69).
if [ -z "$key" ] || [ ! -f "$key" ]; then
  ab_skip_with_reason "rate-limit burst (needs HELIX_TEST_SSH_KEY to produce genuine armored bad-sig logins)" credential_absent
else
  codes=""; count429=0; i=0
  while [ "$i" -lt "$BURST" ]; do
    i=$((i+1)); jar="$(mktemp)"
    page="$(curl -k -s -c "$jar" "$HC_BASE/login" 2>/dev/null)"
    ctok="$(printf '%s' "$page" | grep -oiE 'name="challenge_token" value="[^"]+"' | head -1 | sed -E 's/.*value="([^"]+)".*/\1/')"
    csrf="$(printf '%s' "$page" | grep -oiE 'name="csrf_token" value="[^"]+"' | head -1 | sed -E 's/.*value="([^"]+)".*/\1/')"
    # armored but WRONG signature (signs a different message than the challenge) ->
    # passes CSRF + challenge, fails at step-7 signature verify -> IS rate-counted.
    badsig="$(printf %s "rl-wrong-$i-$$" | ssh-keygen -Y sign -n "${HC_SIGN_NAMESPACE:-helixcode-login}" -f "$key" 2>/dev/null)"
    c="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 -b "$jar" \
      --data-urlencode "challenge_token=$ctok" --data-urlencode "csrf_token=$csrf" --data-urlencode "signature=$badsig" \
      "$HC_BASE/login" 2>/dev/null || echo 000)"
    codes="$codes $c"; [ "$c" = 429 ] && count429=$((count429+1)); rm -f "$jar"
  done
  { echo "assert: a burst of $BURST GENUINE bad-signature logins (valid CSRF + fresh challenge + armored WRONG sig) is throttled with a REAL 429";
    echo "response codes :$codes";
    echo "count 429      : $count429 (want >=1 — limiter throttles genuine post-challenge sig failures after the per-client budget)"; } > "$ev"
  if [ "$count429" -ge 1 ]; then
    ab_pass_with_evidence "RATE-LIMITED: genuine bad-sig burst throttled with a real 429 (count429=$count429/$BURST)" "$ev"
  else
    ab_fail "RATE-LIMITED: no real 429 across $BURST genuine bad-sig logins (count429=$count429) [ev: ${ev#$HC_ROOT/}]"
  fi
  # Cool-down (§11.4.14 leave-clean-state): the burst just exhausted THIS client's
  # per-IP failure budget; wait out the rate window so later suites' valid logins
  # (same client IP) are not throttled by leftover state. Only when we tripped it.
  [ "${count429:-0}" -ge 1 ] && sleep "${HC_RL_COOLDOWN:-17}"
fi

# =========================================================================
h_head "(5) TLS ENFORCED — HTTP :$HC_HTTP -> HTTPS redirect"
ev="$(h_ev tls_enforced)"; hdr="$WORK/http.hdr"
curl -s -D "$hdr" -o /dev/null --max-time 10 "http://127.0.0.1:${HC_HTTP}/" 2>/dev/null || true
code="$(_hdr_code "$hdr")"; loc="$(_hdr_loc "$hdr")"
{ echo "assert: plain HTTP is permanently redirected to HTTPS";
  echo "GET http://127.0.0.1:$HC_HTTP/ -> http_code=$code ; Location=${loc:-<none>}"; } > "$ev"
if { [ "$code" = 301 ] || [ "$code" = 308 ]; } && printf '%s' "$loc" | grep -q '^https://'; then
  ab_pass_with_evidence "TLS ENFORCED: HTTP :$HC_HTTP -> $code $loc" "$ev"
else
  ab_fail "TLS ENFORCED: expected 301/308 -> https://, got code=$code loc=${loc:-none} [ev: ${ev#$HC_ROOT/}]"
fi

h_summary
