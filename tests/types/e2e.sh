#!/usr/bin/env bash
# tests/types/e2e.sh — HelixCode END-TO-END suite (§11.4.169 e2e layer).
#
# Purpose:      Drive the full user login journey through the REAL Caddy edge,
#               exactly as a browser would, and prove it with captured HTTP
#               evidence (§11.4.69) that cannot be a stale/cached pass
#               (§11.4.107): a fresh per-run nonce is used for the wrong-password
#               negative case and embedded in the evidence.
# Journey:      (1) HTTPS edge reachable (/healthz=200);
#               (2) login with the CORRECT password -> 302 + Set-Cookie
#                   `code-server-session` session cookie (value redacted);
#               (3) login with a WRONG (per-run-unique) password -> 200 + NO
#                   session cookie (negative case, proves auth is enforced);
#               (4) authenticated resource fetch: with the freshly-issued cookie,
#                   GET / redirects to the editor (Location contains `folder=`,
#                   NOT `./login`) and following it returns the code-server
#                   workbench (HTTP 200 + editor markers) — an authed request is
#                   observably different from an unauthed one.
# Usage:        bash tests/types/e2e.sh
# Inputs:       deploy/.env via the fixture; the login password is READ from the
#               fixture and NEVER printed or written to evidence (§11.4.10).
# Outputs:      per-run evidence under qa-results/tests/e2e/<run-id>/
# Side-effects: on-demand stack boot only; cookie jars are trap-cleaned; the
#               shared stack is never mutated (read/login probes only).
# Dependencies: bash, curl, podman|docker
# Cross-references: §11.4.69 §11.4.107 §11.4.10 §11.4.98 ; harness.sh stack_fixture.sh
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init e2e

JAR="$(mktemp "${TMPDIR:-/tmp}/hc_e2e_jar.XXXXXX")"
cleanup() { rm -f "$JAR" 2>/dev/null || true; }
trap cleanup EXIT

if ! h_require podman && ! h_require docker; then
  ab_skip_with_reason "e2e suite (no container runtime on PATH)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi

# per-run nonce so no cache/stale response can satisfy the negative case (§11.4.107)
NONCE="${H_RUNID}-$RANDOM"

# --------------------------------------------------------------------------
# (1) HTTPS edge reachable
# --------------------------------------------------------------------------
h_head "HTTPS edge reachable"
ev="$(h_ev edge_reachable)"
hz="$(hc_https_code /healthz)"; root="$(hc_https_code /)"
{ echo "nonce: $NONCE"; echo "/healthz -> $hz"; echo "/ -> $root"; } > "$ev"
if [ "$hz" = 200 ]; then ab_pass_with_evidence "Caddy HTTPS edge reachable (/healthz=200, /=$root)" "$ev"
else ab_fail "HTTPS edge not reachable (/healthz=$hz) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (2) login CORRECT -> 302 + Set-Cookie session cookie (fresh jar)
# --------------------------------------------------------------------------
h_head "login with CORRECT password -> 302 + session cookie"
ev="$(h_ev login_correct)"
: > "$JAR"
code_ok="$(curl -k -s -c "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 \
  --data-urlencode "password=${HC_PASSWORD}" "$HC_BASE/login" 2>/dev/null || echo 000)"
# capture response headers (cookie value redacted) as evidence
curl -k -s -D - -o /dev/null --max-time 15 \
  --data-urlencode "password=${HC_PASSWORD}" "$HC_BASE/login" 2>/dev/null \
  | grep -iE '^(HTTP/|location:|set-cookie:)' \
  | sed -E 's/(set-cookie:[[:space:]]*[^=]+=)[^;]+/\1<redacted>/I' >> "$ev"
cookie_name="$(awk 'NF && $1!~/^#/ {print $6}' "$JAR" 2>/dev/null | grep -m1 . )"
{ echo "nonce: $NONCE"; echo "POST /login (correct) -> $code_ok"; echo "session cookie name: ${cookie_name:-<none>}"; } >> "$ev"
if [ "$code_ok" = 302 ] && [ "$cookie_name" = "code-server-session" ]; then
  ab_pass_with_evidence "correct password -> 302 + Set-Cookie code-server-session" "$ev"
else ab_fail "correct-login journey wrong (code=$code_ok cookie=${cookie_name:-none}) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (3) login WRONG (per-run-unique) -> 200 + NO session cookie  (negative case)
# --------------------------------------------------------------------------
h_head "login with WRONG password -> 200 + NO session cookie"
ev="$(h_ev login_wrong)"
WRONGJAR="$(mktemp "${TMPDIR:-/tmp}/hc_e2e_wjar.XXXXXX")"
code_bad="$(curl -k -s -c "$WRONGJAR" -o /dev/null -w '%{http_code}' --max-time 15 \
  --data-urlencode "password=wrong-${NONCE}" "$HC_BASE/login" 2>/dev/null || echo 000)"
bad_cookie="$(awk 'NF && $1!~/^#/ {print $6}' "$WRONGJAR" 2>/dev/null | grep -c 'code-server-session' )"
{ echo "nonce: $NONCE"
  echo "POST /login (wrong pw = 'wrong-${NONCE}') -> $code_bad"
  echo "session cookies issued for wrong pw: $bad_cookie (want 0)"; } > "$ev"
rm -f "$WRONGJAR" 2>/dev/null || true
if [ "$code_bad" = 200 ] && [ "$bad_cookie" = 0 ]; then
  ab_pass_with_evidence "wrong password -> 200 and NO session cookie (auth enforced)" "$ev"
else ab_fail "wrong-login negative case failed (code=$code_bad cookies=$bad_cookie) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (4) authenticated resource fetch (uses the fresh cookie jar from step 2)
# --------------------------------------------------------------------------
h_head "authenticated resource fetch with session cookie"
ev="$(h_ev authed_fetch)"
unauth_loc="$(curl -k -s -D - -o /dev/null --max-time 15 "$HC_BASE/" 2>/dev/null | sed -nE 's/^[Ll]ocation:[[:space:]]*//p' | tr -d '\r')"
authed_loc="$(curl -k -s -b "$JAR" -D - -o /dev/null --max-time 15 "$HC_BASE/" 2>/dev/null | sed -nE 's/^[Ll]ocation:[[:space:]]*//p' | tr -d '\r')"
body="$(mktemp "${TMPDIR:-/tmp}/hc_e2e_body.XXXXXX")"
authed_final="$(curl -k -s -b "$JAR" -L -o "$body" -w '%{http_code}' --max-time 20 "$HC_BASE/" 2>/dev/null || echo 000)"
editor_markers="$(grep -icE 'workbench|code-server|vscode' "$body" 2>/dev/null || true)"; editor_markers="${editor_markers:-0}"
{ echo "nonce: $NONCE"
  echo "unauthed GET / Location : ${unauth_loc:-<none>}"
  echo "authed   GET / Location : ${authed_loc:-<none>}"
  echo "authed  GET / (-L) final code: $authed_final"
  echo "editor markers in authed body (workbench|code-server|vscode): $editor_markers"; } > "$ev"
rm -f "$body" 2>/dev/null || true
if [ -n "$authed_loc" ] && [ "$authed_loc" != "$unauth_loc" ] && echo "$authed_loc" | grep -q 'folder' \
   && [ "$authed_final" = 200 ] && [ "${editor_markers:-0}" -ge 1 ]; then
  ab_pass_with_evidence "authenticated fetch differs from unauthed (Location folder=… vs ./login) + editor loads (200)" "$ev"
else ab_fail "authed resource fetch not distinguishable/authed (authed_loc='$authed_loc' final=$authed_final markers=$editor_markers) [ev: ${ev#$HC_ROOT/}]"; fi

h_summary
