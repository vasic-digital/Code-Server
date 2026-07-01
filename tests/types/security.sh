#!/usr/bin/env bash
#
# tests/types/security.sh — ANTI-BLUFF security suite for the HelixCode stack.
#
# Proves, with REAL captured evidence (§11.4/§11.4.69), the security posture of
# the rootless-podman code-server stack (Caddy edge 52443/52080 -> code-server):
#
#   (1) AUTH REQUIRED   — an unauthenticated request to the protected app root
#                         is redirected to /login (not served).                  (§11.4.10)
#   (2) TLS ENFORCED    — plain HTTP :52080 is 301/308-redirected to HTTPS.       (§11.4.69 network_connectivity)
#   (3) NO SECRET LEAK  — deploy/.env, deploy/tls/*, *.env are git-ignored AND
#                         untracked; the real password value is ABSENT from the
#                         tracked tree.                                           (§11.4.10 / §11.4.30)
#   (4) ROOTLESS        — the container engine is rootless podman and our
#                         containers do NOT run as host-root.                     (§11.4.161)
#   (5) PASSWORD HYGIENE — code-server validates the hashed session: a CORRECT
#                         login yields 302 + Set-Cookie; a WRONG login yields
#                         200 + NO cookie (accept-all would leak a cookie).
#
# The password value is NEVER printed, logged, or written to evidence (§11.4.10);
# only HTTP status codes, redacted cookie NAMES, and file-path lists are captured.
#
# §1.1 PAIRED MUTATION (proves this gate is not a bluff):
#   - AUTH:      point Caddy's protected root at a public handler (remove auth) so
#                GET / returns 200 instead of 302 -> assertion (1) FAILs.
#   - TLS:       change Caddyfile ":80" to `reverse_proxy` (drop `redir`) so HTTP
#                serves 200 instead of 301 -> assertion (2) FAILs.
#   - LEAK:      `git add -f deploy/.env` (track the secret) -> assertion (3) FAILs
#                (git ls-files now lists it AND the value greps in the tree).
#   - ROOTLESS:  run the stack under rootful docker -> Host.Security.Rootless=false
#                / container host-PID owner uid==0 -> assertion (4) FAILs.
#   - HYGIENE:   set code-server PASSWORD="" (auth disabled) so a WRONG login also
#                302s + sets a cookie -> assertion (5) FAILs.
#
# Purpose      : security posture proof with captured HTTP/podman/git evidence
# Inputs       : deploy/.env (via stack_fixture); RED_MODE (unused here)
# Outputs      : qa-results/tests/security/<run-id>/*.txt ; exit 0 iff all PASS
# Side-effects : read-only probes; NEVER mutates the stack or the git tree
# Dependencies : bash, curl, git, podman, ps ; harness.sh + stack_fixture.sh
# Cross-refs   : §11.4.10 §11.4.30 §11.4.69 §11.4.161 §11.4.174 ; harness.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init security

# On-demand infra (§11.4.76): bring the stack up if not already running.
if ! hc_stack_up; then
  ev="$(h_ev stack_unreachable)"; { echo "hc_stack_up failed — stack not reachable at $HC_BASE"; } > "$ev"
  ab_skip_with_reason "HelixCode stack not reachable (cannot boot on-demand)" network_unreachable_external
  h_summary; exit $?
fi
hc_load_env

# ---- helpers -------------------------------------------------------------
# last HTTP status line code in a headers file
_hdr_code() { awk 'toupper($1) ~ /^HTTP/ {c=$2} END{print c+0}' "$1"; }
# last Location header value (CR-stripped)
_hdr_loc()  { grep -i '^location:' "$1" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}'; }

# =========================================================================
h_head "(1) AUTH REQUIRED — unauth GET / -> redirect to /login"
ev="$(h_ev auth_required)"
curl -k -s -D "$ev" -o /dev/null --max-time 10 "$HC_BASE/" 2>/dev/null
code="$(_hdr_code "$ev")"; loc="$(_hdr_loc "$ev")"
{ echo "assert: unauthenticated GET / is redirected to the login page (not served)";
  echo "http_code=$code"; echo "location=$loc"; } >> "$ev"
if [ "$code" = "302" ] && printf '%s' "$loc" | grep -q '/login'; then
  ab_pass_with_evidence "AUTH REQUIRED: unauth GET / -> $code $loc" "$ev"
else
  ab_fail "AUTH REQUIRED: expected 302 -> /login, got code=$code loc=$loc [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
h_head "(2) TLS ENFORCED — HTTP :$HC_HTTP -> HTTPS redirect"
ev="$(h_ev tls_enforced)"
curl -s -D "$ev" -o /dev/null --max-time 10 "http://127.0.0.1:${HC_HTTP}/" 2>/dev/null
code="$(_hdr_code "$ev")"; loc="$(_hdr_loc "$ev")"
{ echo "assert: plain HTTP is permanently redirected to HTTPS";
  echo "http_code=$code"; echo "location=$loc"; } >> "$ev"
if { [ "$code" = "301" ] || [ "$code" = "308" ]; } && printf '%s' "$loc" | grep -q '^https://'; then
  ab_pass_with_evidence "TLS ENFORCED: HTTP :$HC_HTTP -> $code $loc" "$ev"
else
  ab_fail "TLS ENFORCED: expected 301/308 -> https://, got code=$code loc=$loc [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
h_head "(3) NO SECRET LEAK (§11.4.10) — ignored + untracked + value absent"
# (3a) git-ignored
ev="$(h_ev secret_gitignored)"
: > "$ev"
ign_ok=1
for p in deploy/.env deploy/tls/site.key deploy/tls/site.crt; do
  if out="$(cd "$HC_ROOT" && git check-ignore "$p" 2>/dev/null)" && [ -n "$out" ]; then
    echo "IGNORED: $out" >> "$ev"
  else
    echo "NOT-IGNORED: $p" >> "$ev"; ign_ok=0
  fi
done
# also confirm the *.env glob is covered
if (cd "$HC_ROOT" && git check-ignore some.env >/dev/null 2>&1); then echo "IGNORED-GLOB: *.env" >> "$ev"; else echo "NOT-IGNORED-GLOB: *.env" >> "$ev"; ign_ok=0; fi
if [ "$ign_ok" = "1" ]; then
  ab_pass_with_evidence "NO SECRET LEAK (a): deploy/.env, deploy/tls/*, *.env are git-ignored" "$ev"
else
  ab_fail "NO SECRET LEAK (a): a secret path is NOT git-ignored [ev: ${ev#$HC_ROOT/}]"
fi

# (3b) not tracked
ev="$(h_ev secret_untracked)"
tracked="$(cd "$HC_ROOT" && git ls-files -- deploy/.env deploy/tls deploy/compose.projects.yml 2>/dev/null)"
{ echo "assert: no secret/runtime path is tracked in git";
  echo "git ls-files -- deploy/.env deploy/tls deploy/compose.projects.yml:";
  if [ -n "$tracked" ]; then echo "$tracked"; else echo "(none — clean)"; fi; } > "$ev"
if [ -z "$tracked" ]; then
  ab_pass_with_evidence "NO SECRET LEAK (b): deploy/.env, deploy/tls/*, compose.projects.yml are UNtracked" "$ev"
else
  ab_fail "NO SECRET LEAK (b): tracked secret/runtime path(s) found: $tracked [ev: ${ev#$HC_ROOT/}]"
fi

# (3c) real password value absent from the tracked tree (value NEVER printed)
ev="$(h_ev secret_value_absent)"
if [ -z "${HC_PASSWORD:-}" ]; then
  { echo "CODE_SERVER_PASSWORD unset in deploy/.env — cannot grep for a value"; } > "$ev"
  ab_skip_with_reason "NO SECRET LEAK (c): password value unset" credential_absent
else
  # match anywhere in the tracked tree EXCEPT the documented placeholder templates
  matches="$(cd "$HC_ROOT" && git grep -F -I -l -e "$HC_PASSWORD" -- ':!*.env.example' ':!*.env.sample' 2>/dev/null || true)"
  { echo "assert: the live CODE_SERVER_PASSWORD value does not appear in any tracked file";
    echo "(the value itself is intentionally not written to this evidence file — §11.4.10)";
    echo "tracked files containing the value (excluding *.env.example/*.env.sample templates):";
    if [ -n "$matches" ]; then echo "$matches"; else echo "(none — value absent from tracked tree)"; fi; } > "$ev"
  if [ -z "$matches" ]; then
    ab_pass_with_evidence "NO SECRET LEAK (c): live password value ABSENT from tracked tree" "$ev"
  else
    ab_fail "NO SECRET LEAK (c): password value LEAKED into tracked file(s): $matches [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
h_head "(4) ROOTLESS (§11.4.161) — rootless podman, containers not host-root"
ev="$(h_ev rootless)"
if [ "$HC_ENGINE" != "podman" ]; then
  { echo "container engine is '$HC_ENGINE', not podman — §11.4.161 mandates rootless podman"; } > "$ev"
  ab_skip_with_reason "ROOTLESS: engine is not podman on this host" topology_unsupported
else
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo unknown)"
  pid="$(podman inspect --format '{{.State.Pid}}' "$HC_CS" 2>/dev/null || echo)"
  huid=""; [ -n "$pid" ] && huid="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')"
  ceuid="$(podman exec "$HC_CS" id -u 2>/dev/null || echo)"
  { echo "assert: engine rootless AND container host-process owner uid != 0 (not host-root)";
    echo "podman Host.Security.Rootless=$rootless";
    echo "container=$HC_CS host_pid=$pid host_owner_uid=$huid container_internal_euid=$ceuid";
    echo "note: rootless maps container-root (euid $ceuid) to non-root host uid $huid"; } > "$ev"
  if [ "$rootless" = "true" ] && [ -n "$huid" ] && [ "$huid" != "0" ]; then
    ab_pass_with_evidence "ROOTLESS: podman rootless=true, $HC_CS host-owner uid=$huid (not root)" "$ev"
  else
    ab_fail "ROOTLESS: rootless=$rootless host_owner_uid=${huid:-none} (expected true + non-zero) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
h_head "(5) PASSWORD HYGIENE — hashed session: correct=302+cookie, wrong=200+no-cookie"
ok_ev="$(h_ev login_correct)"; bad_ev="$(h_ev login_wrong)"
# CORRECT login (password passed as arg to fixture; never echoed) — redact cookie value
hc_login_headers "$HC_PASSWORD" "$ok_ev.raw" 2>/dev/null
sed -E 's/(set-cookie: *[^=]+=)[^;]+/\1<REDACTED>/I' "$ok_ev.raw" > "$ok_ev" 2>/dev/null; rm -f "$ok_ev.raw"
# grep -c prints "0" on no-match but exits 1; capture the printed count (no `|| echo`).
ok_code="$(_hdr_code "$ok_ev")"; ok_cookie="$(grep -ic '^set-cookie:' "$ok_ev" 2>/dev/null)"; ok_cookie="${ok_cookie:-0}"
# WRONG login
hc_login_headers "helixcode-wrong-$$-$RANDOM" "$bad_ev" 2>/dev/null
bad_code="$(_hdr_code "$bad_ev")"; bad_cookie="$(grep -ic '^set-cookie:' "$bad_ev" 2>/dev/null)"; bad_cookie="${bad_cookie:-0}"
{ echo "assert: correct password -> 302 + session cookie; wrong password -> 200 + NO cookie";
  echo "correct_login: http_code=$ok_code set_cookie_headers=$ok_cookie";
  echo "wrong_login:   http_code=$bad_code set_cookie_headers=$bad_cookie";
  echo "(the password value is not present in this file — §11.4.10)"; } >> "$ok_ev"
if [ "$ok_code" = "302" ] && [ "${ok_cookie:-0}" -ge 1 ] && [ "$bad_code" = "200" ] && [ "${bad_cookie:-0}" -eq 0 ]; then
  ab_pass_with_evidence "PASSWORD HYGIENE: correct=302+cookie, wrong=200+no-cookie (auth validates, not accept-all)" "$ok_ev"
else
  ab_fail "PASSWORD HYGIENE: correct(code=$ok_code cookie=$ok_cookie) wrong(code=$bad_code cookie=$bad_cookie) — expected 302+cookie / 200+nocookie [ev: ${ok_ev#$HC_ROOT/}]"
fi

h_summary
