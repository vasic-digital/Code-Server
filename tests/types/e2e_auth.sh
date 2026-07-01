#!/usr/bin/env bash
#
# tests/types/e2e_auth.sh — SSH-KEY auth login journey (§11.4.169 e2e layer).
#
# The 2026-07-01 auth pivot replaced password login with an SSH-KEY
# challenge-response gate (spec docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md).
# This suite drives the REAL user journey through the Caddy TLS edge and proves it
# with captured HTTP evidence (§11.4.69), plus a SELF-CONTAINED crypto smoke that
# needs no stack.
#
# Assertions:
#   (A) SIGNING SMOKE (no stack): `ssh-keygen -Y sign` yields an armored signature
#       and `-Y verify` accepts it for the correct nonce and REJECTS a wrong one —
#       proves the challenge-response primitive the login rests on, RIGHT NOW.
#   (B) unauthenticated GET /  -> redirected to /login (or 401 via the gate).
#   (C) login page shows the `ssh-keygen -Y sign` command AND has NO password field.
#   (D) VALID ssh-key login -> session cookie issued + authed GET / serves the
#       editor. Needs a key present in the gate's allowed_signers: uses
#       $HELIX_TEST_SSH_KEY when the operator/conductor provides one; otherwise
#       SKIP-with-reason(credential_absent) — a valid-login PASS is NEVER faked.
#   (E) tampered signature -> denied (no session cookie); absent signature -> denied.
#
# ANTI-BLUFF (§11.4 / §11.4.1 / §11.4.69): when the live stack is not deployed the
# stack-dependent steps SKIP-with-reason(topology_unsupported) — never a fake PASS.
# Real green for (B)-(E) happens at the conductor's live-validation step (§11.4.40).
# Mocks are FORBIDDEN here (e2e type, §11.4.27); every PASS cites captured evidence.
#
# Usage:        bash tests/types/e2e_auth.sh
# Inputs:       deploy/.env + HELIX_AUTH_ADDR/HELIX_CODESERVER_ADDR via the fixture ;
#               optional HELIX_TEST_SSH_KEY (authorized private key) / HELIX_AUTH_PRINCIPAL
# Outputs:      per-run evidence under qa-results/tests/e2e_auth/<run-id>/
# Side-effects: on-demand probes only; throwaway keys + cookie jars are trap-cleaned;
#               the shared stack is never mutated (GET/login POST probes only).
# Dependencies: bash, ssh-keygen ; curl (live steps) ; coreutils
# Cross-refs:   §11.4.69 §11.4.98 §11.4.107 §11.4.10 §11.4.6 ; harness.sh stack_fixture.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init e2e_auth

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_e2e_auth.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"

# =========================================================================
# (A) SELF-CONTAINED signing-helper crypto smoke — REAL evidence, NO stack.
# =========================================================================
h_head "(A) ssh-key sign/verify crypto smoke (self-contained, no stack)"
ev="$(h_ev sign_smoke)"
if hc_sshkey_sign_smoke "$ev" "$PRINCIPAL"; then
  ab_pass_with_evidence "ssh-keygen -Y sign -> armored sig; -Y verify ACCEPTS correct nonce, REJECTS wrong (challenge-response proven)" "$ev"
else
  rc=$?
  if [ "$rc" = 2 ]; then
    ab_skip_with_reason "signing smoke: ssh-keygen not on PATH" topology_unsupported
  else
    ab_fail "signing smoke: sign/verify path failed [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# --------- from here on the LIVE auth-pivot stack is required -------------
if ! h_require curl; then
  ab_skip_with_reason "e2e_auth live journey: curl not on PATH" topology_unsupported
  h_summary; exit $?
fi
if ! hc_new_stack_up; then
  ev="$(h_ev stack_down)"
  { echo "auth-pivot ssh-key stack not deployed (conductor deploys it live later)";
    echo "probe: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "e2e_auth live journey: ssh-key auth stack not deployed ($HC_NEW_STACK_DETAIL)" topology_unsupported
  h_summary; exit $?
fi

# =========================================================================
# (B) unauthenticated GET / -> redirect to login (or 401 via the gate).
# =========================================================================
h_head "(B) unauthenticated GET / -> browser redirected to /login; API stays 401"
ev="$(h_ev unauth_root)"; hdr="$WORK/unauth.hdr"; ahdr="$WORK/unauth_api.hdr"
# Browser NAVIGATION (Accept: text/html) MUST land on the login form, not a bare,
# bodyless 401 — regression guard for the "This page isn't working" failure where
# browsing the site root died on an un-redirected 401.
curl -k -s -D "$hdr" -o /dev/null --max-time 15 -H 'Accept: text/html,application/xhtml+xml' "$HC_BASE/" 2>/dev/null || true
code="$(awk 'toupper($1)~/^HTTP/{c=$2} END{print c+0}' "$hdr" 2>/dev/null)"
loc="$(grep -i '^location:' "$hdr" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')"
# API/XHR/asset (Accept: */*) MUST stay 401 — a programmatic caller must never be
# served an HTML login page in place of its expected payload.
curl -k -s -D "$ahdr" -o /dev/null --max-time 15 -H 'Accept: */*' "$HC_BASE/" 2>/dev/null || true
apicode="$(awk 'toupper($1)~/^HTTP/{c=$2} END{print c+0}' "$ahdr" 2>/dev/null)"
{ echo "assert: unauth browser GET / -> /login redirect; unauth API GET / -> 401 (editor NEVER served)";
  echo "browser (Accept: text/html) -> http_code=$code ; Location=${loc:-<none>}";
  echo "api     (Accept: */*)       -> http_code=$apicode"; } > "$ev"
browser_login_redirect=0
{ [ "$code" = 302 ] || [ "$code" = 303 ] || [ "$code" = 307 ]; } && printf '%s' "$loc" | grep -qi 'login' && browser_login_redirect=1
if [ "$browser_login_redirect" = 1 ] && [ "$apicode" = 401 ]; then
  ab_pass_with_evidence "unauth GET /: browser -> $code redirect to /login, API -> 401 (auth enforced, editor not served)" "$ev"
elif [ "$code" = 401 ] && [ "$apicode" = 401 ]; then
  ab_pass_with_evidence "unauth GET / -> 401 for both browser + API (gate fail-closed, editor not served)" "$ev"
else
  ab_fail "unauth GET / not properly protected (browser=$code loc=${loc:-none} api=$apicode) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
# (C) login page shows the ssh-keygen sign command AND has NO password field.
# =========================================================================
h_head "(C) login page: ssh-keygen sign command present, NO password field"
ev="$(h_ev login_page)"; page="$WORK/login.html"
curl -k -s --max-time 15 "$HC_BASE/login" -o "$page" 2>/dev/null || true
has_signcmd=0; grep -qiE 'ssh-keygen[[:space:]]+-Y[[:space:]]+sign' "$page" 2>/dev/null && has_signcmd=1
has_pw=0; grep -qiE "<input[^>]*type[[:space:]]*=[[:space:]]*[\"']?password" "$page" 2>/dev/null && has_pw=1
has_pwhidden=0; hc_scrape_hidden_inputs "$page" | grep -qiE '^password=' && has_pwhidden=1
nonce="$(hc_extract_challenge "$page")"; nonce_ok=0; [ -n "$nonce" ] && nonce_ok=1
{ echo "assert: the login page instructs ssh-keygen signing and exposes NO password input";
  echo "login page bytes                  : $(wc -c < "$page" 2>/dev/null | tr -d ' ')";
  echo "shows 'ssh-keygen -Y sign' command: $([ $has_signcmd = 1 ] && echo yes || echo no) (want yes)";
  echo "contains a <input type=password>  : $([ $has_pw = 1 ] && echo yes || echo no) (want no)";
  echo "hidden field literally 'password' : $([ $has_pwhidden = 1 ] && echo yes || echo no) (want no)";
  echo "challenge nonce extractable       : $([ $nonce_ok = 1 ] && echo yes || echo no) (want yes)"; } > "$ev"
if [ $has_signcmd = 1 ] && [ $has_pw = 0 ] && [ $has_pwhidden = 0 ] && [ $nonce_ok = 1 ]; then
  ab_pass_with_evidence "login page shows ssh-keygen sign command + challenge, NO password field" "$ev"
else
  ab_fail "login page wrong (signcmd=$has_signcmd password_input=$has_pw password_hidden=$has_pwhidden nonce=$nonce_ok) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
# (D) VALID ssh-key login -> session cookie + editor. Needs an authorized key.
# =========================================================================
h_head "(D) VALID ssh-key login -> session cookie + editor loads"
ev="$(h_ev valid_login)"; JAR="$WORK/jar"
KEYFILE="${HELIX_TEST_SSH_KEY:-}"
if [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ]; then
  if hc_sshkey_login "$HC_BASE" "$KEYFILE" "$JAR" "$PRINCIPAL"; then
    body="$WORK/body.html"
    authed_final="$(curl -k -s -b "$JAR" -L -o "$body" -w '%{http_code}' --max-time 20 "$HC_BASE/" 2>/dev/null || echo 000)"
    markers="$(grep -icE 'workbench|code-server|vscode' "$body" 2>/dev/null || true)"; markers="${markers:-0}"
    { echo "assert: valid ssh-key login issues a session cookie and the editor then loads";
      echo "POST /login code           : $HC_SSHKEY_CODE";
      echo "session cookie name         : ${HC_SSHKEY_COOKIE:-<none>} (new: ${HC_SSHKEY_NEWCOOKIE:-<none>})";
      echo "scraped hidden fields       : ${HC_SSHKEY_FIELDS:-<none>}";
      echo "challenge nonce             : ${HC_SSHKEY_NONCE:-<none>}";
      echo "authed GET / (-L) final code: $authed_final ; editor markers: $markers";
      echo "(the signature/private key are never written to evidence — §11.4.10)"; } > "$ev"
    if { [ "$HC_SSHKEY_CODE" = 302 ] || [ "$HC_SSHKEY_CODE" = 303 ]; } && [ -n "$HC_SSHKEY_COOKIE" ] \
       && [ "$authed_final" = 200 ] && [ "$markers" -ge 1 ]; then
      ab_pass_with_evidence "valid ssh-key login -> $HC_SSHKEY_CODE + session cookie + editor loads (200)" "$ev"
    else
      ab_fail "valid ssh-key login journey incomplete (code=$HC_SSHKEY_CODE cookie=${HC_SSHKEY_COOKIE:-none} final=$authed_final markers=$markers) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    { echo "hc_sshkey_login returned failure with an authorized key present";
      echo "POST /login code=$HC_SSHKEY_CODE cookie=${HC_SSHKEY_COOKIE:-none} new=${HC_SSHKEY_NEWCOOKIE:-none}";
      echo "scraped hidden fields=${HC_SSHKEY_FIELDS:-none} nonce=${HC_SSHKEY_NONCE:-none}"; } > "$ev"
    ab_fail "valid ssh-key login did not yield a session cookie (code=$HC_SSHKEY_CODE) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "no authorized test key available (HELIX_TEST_SSH_KEY unset or unreadable)";
    echo "a genuine valid-login PASS requires a key present in the gate's allowed_signers";
    echo "(no documented tests/-scope hook exists to authorize a throwaway key; the";
    echo " autonomous valid-login path binds once the conductor provides HELIX_TEST_SSH_KEY";
    echo " — §11.4.98). This is a SKIP-with-reason, never a faked PASS (§11.4/§11.4.69)."; } > "$ev"
  ab_skip_with_reason "valid ssh-key login: no authorized test key (HELIX_TEST_SSH_KEY) available" credential_absent
fi

# =========================================================================
# (E) tampered / absent signature -> denied (no session cookie).
# =========================================================================
h_head "(E) tampered/absent signature -> denied (fail-closed)"
ev="$(h_ev bad_signature)"
BADJAR1="$WORK/badjar1"; BADJAR2="$WORK/badjar2"; badpage="$WORK/badlogin.html"
: > "$BADJAR1"; : > "$BADJAR2"

# (E1) garbage signature
hc_sshkey_challenge "$HC_BASE" "$BADJAR1" "$badpage" || true
tampered_sig=$'-----BEGIN SSH SIGNATURE-----\nU1NIU0lHtampered-not-a-real-signature==\n-----END SSH SIGNATURE-----'
if hc_sshkey_submit "$HC_BASE" "$BADJAR1" "$tampered_sig" "$PRINCIPAL"; then e1_denied=0; else e1_denied=1; fi
e1_code="$HC_SSHKEY_CODE"; e1_new="${HC_SSHKEY_NEWCOOKIE:-}"

# (E2) absent signature (empty)
hc_sshkey_challenge "$HC_BASE" "$BADJAR2" "$badpage" || true
if hc_sshkey_submit "$HC_BASE" "$BADJAR2" "" "$PRINCIPAL"; then e2_denied=0; else e2_denied=1; fi
e2_code="$HC_SSHKEY_CODE"; e2_new="${HC_SSHKEY_NEWCOOKIE:-}"

{ echo "assert: neither a tampered nor an absent signature yields a session cookie (fail-closed)";
  echo "tampered signature POST -> code=$e1_code new_session_cookie=${e1_new:-<none>} denied=$e1_denied (want denied=1)";
  echo "absent   signature POST -> code=$e2_code new_session_cookie=${e2_new:-<none>} denied=$e2_denied (want denied=1)"; } > "$ev"
if [ "$e1_denied" = 1 ] && [ "$e2_denied" = 1 ]; then
  ab_pass_with_evidence "tampered signature (code=$e1_code) AND absent signature (code=$e2_code) -> denied, no session cookie" "$ev"
else
  ab_fail "bad-signature not denied (tampered denied=$e1_denied code=$e1_code ; absent denied=$e2_denied code=$e2_code) [ev: ${ev#$HC_ROOT/}]"
fi

h_summary
