#!/usr/bin/env bash
#
# tests/types/helixqa_auth.sh — §11.4.169 HelixQA layer for the ssh-key auth pivot.
#
# Runs tests/banks/helixcode-auth-helixqa.yaml as an AUTONOMOUS QA session for the
# 2026-07-01 auth pivot (spec 2026-07-01-auth-pivot-ssh-key.md): every
# autonomously-HTTP-drivable case is executed live with captured positive evidence
# (§11.4.69). The valid-login journey binds to a real authorized key
# ($HELIX_TEST_SSH_KEY) and SKIPs credential_absent otherwise. The real in-browser
# editor interaction (HCA-QA-UI-001) is honestly SKIPPED operator_attended per
# §11.4.3/§11.4.52 (tracked follow-up: wire a browser-automation adapter) — never a
# faked UI pass. No secret is written to evidence (§11.4.10).
#
# §1.1 paired mutation: make HCA-QA-003 accept /auth=200 with no cookie (fail-open),
# or HCA-QA-UI-001 emit a PASS without a browser -> the honest-skip/assert invariant FAILs.
#
# ANTI-BLUFF (§11.4/§11.4.1/§11.4.69/§11.4.98): mocks are FORBIDDEN (HelixQA is an
# integration+ type, §11.4.27); when the live stack is not deployed the session
# SKIPs-with-reason(topology_unsupported) — real green happens at conductor
# live-validation (§11.4.40).
#
# Cross-refs: §11.4.169 §11.4.27 §11.4.52 §11.4.3 §11.4.69 §11.4.10 ;
#             tests/banks/helixcode-auth-helixqa.yaml ; harness.sh stack_fixture.sh
set -uo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$_here/../lib/harness.sh"
. "$_here/../lib/stack_fixture.sh"

h_init helixqa_auth
BANK="$HC_ROOT/tests/banks/helixcode-auth-helixqa.yaml"
[ -f "$BANK" ] && h_log "bank: ${BANK#$HC_ROOT/}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_qa_auth.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"

if ! h_require curl; then
  ab_skip_with_reason "HelixQA auth session: curl not on PATH" topology_unsupported
  h_summary; exit $?
fi
if ! hc_new_stack_up; then
  ev="$(h_ev stack_down)"
  { echo "auth-pivot ssh-key stack not deployed (conductor deploys it live later)";
    echo "probe: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "HelixQA auth session: ssh-key auth stack not deployed ($HC_NEW_STACK_DETAIL)" topology_unsupported
  h_summary; exit $?
fi

# =========================================================================
# HCA-QA-001 TLS edge reachable
# =========================================================================
h_head "HCA-QA-001 TLS edge reachable"
ev="$(h_ev qa001_edge)"; code="$(hc_https_code /)"
echo "GET / -> $code (expect non-000; unauth request denied at the edge)" > "$ev"
if [ "$code" != "000" ]; then ab_pass_with_evidence "HCA-QA-001: TLS edge reachable (GET / -> $code)" "$ev"
else ab_fail "HCA-QA-001: edge unreachable [ev: ${ev#$HC_ROOT/}]"; fi

# =========================================================================
# HCA-QA-002 login page: ssh-key challenge present, NO password field
# =========================================================================
h_head "HCA-QA-002 login page (ssh-key challenge, no password)"
ev="$(h_ev qa002_login_page)"; page="$WORK/login.html"
curl -k -s --max-time 15 "$HC_BASE/login" -o "$page" 2>/dev/null || true
has_signcmd=0; grep -qiE 'ssh-keygen[[:space:]]+-Y[[:space:]]+sign' "$page" 2>/dev/null && has_signcmd=1
has_pw=0; grep -qiE "<input[^>]*type[[:space:]]*=[[:space:]]*[\"']?password" "$page" 2>/dev/null && has_pw=1
has_pwhidden=0; hc_scrape_hidden_inputs "$page" | grep -qiE '^password=' && has_pwhidden=1
nonce="$(hc_extract_challenge "$page")"; nonce_ok=0; [ -n "$nonce" ] && nonce_ok=1
{ echo "assert: /login shows the ssh-keygen sign command + a challenge, and has NO password field";
  echo "login page bytes            : $(wc -c < "$page" 2>/dev/null | tr -d ' ')";
  echo "shows 'ssh-keygen -Y sign'  : $([ $has_signcmd = 1 ] && echo yes || echo no) (want yes)";
  echo "<input type=password>       : $([ $has_pw = 1 ] && echo yes || echo no) (want no)";
  echo "hidden field 'password'     : $([ $has_pwhidden = 1 ] && echo yes || echo no) (want no)";
  echo "challenge nonce extractable : $([ $nonce_ok = 1 ] && echo yes || echo no) (want yes)"; } > "$ev"
if [ $has_signcmd = 1 ] && [ $has_pw = 0 ] && [ $has_pwhidden = 0 ] && [ $nonce_ok = 1 ]; then
  ab_pass_with_evidence "HCA-QA-002: login page is ssh-key challenge-response (sign command + nonce, NO password)" "$ev"
else
  ab_fail "HCA-QA-002: login page wrong (signcmd=$has_signcmd pw=$has_pw pw_hidden=$has_pwhidden nonce=$nonce_ok) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
# HCA-QA-003 forward-auth fails closed (no cookie -> 401, forged -> 401)
# =========================================================================
h_head "HCA-QA-003 forward-auth fails closed"
ev="$(h_ev qa003_fail_closed)"
nc="$(hc_http_code "http://${HC_GATE_ADDR}/auth")"
fc_hdr="$WORK/qa003_forged.hdr"
curl -s -D "$fc_hdr" -o /dev/null --max-time 10 -H 'Cookie: session=forged-not-a-valid-session' "http://${HC_GATE_ADDR}/auth" 2>/dev/null || true
fc="$(awk 'toupper($1)~/^HTTP/{c=$2} END{print c+0}' "$fc_hdr" 2>/dev/null)"
{ echo "assert: the gate's forward-auth check denies by default (fail-closed)";
  echo "GET /auth (no cookie)     -> $nc (want 401)";
  echo "GET /auth (forged cookie) -> $fc (want 401)"; } > "$ev"
if [ "$nc" = 401 ] && [ "$fc" = 401 ]; then
  ab_pass_with_evidence "HCA-QA-003: forward-auth fails closed (/auth=401 without and with a forged cookie)" "$ev"
else
  ab_fail "HCA-QA-003: forward-auth not fail-closed (no-cookie=$nc forged=$fc — want 401/401) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
# HCA-QA-004 valid ssh-key login journey (authorized key, else honest SKIP)
# =========================================================================
h_head "HCA-QA-004 valid ssh-key login journey"
ev="$(h_ev qa004_valid_login)"; JAR="$WORK/qa004.jar"
KEYFILE="${HELIX_TEST_SSH_KEY:-}"
if ! h_require ssh-keygen; then
  { echo "ssh-keygen not on PATH — cannot drive a valid ssh-key login"; } > "$ev"
  ab_skip_with_reason "HCA-QA-004 valid login: ssh-keygen not on PATH" topology_unsupported
elif [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ]; then
  if hc_sshkey_login "$HC_BASE" "$KEYFILE" "$JAR" "$PRINCIPAL"; then
    body="$WORK/qa004.body"
    final="$(curl -k -s -b "$JAR" -L -o "$body" -w '%{http_code}' --max-time 20 "$HC_BASE/" 2>/dev/null || echo 000)"
    markers="$(grep -icE 'workbench|code-server|vscode|monaco' "$body" 2>/dev/null || true)"; markers="${markers:-0}"
    { echo "assert: an authorized ssh-key login mints a session cookie AND the editor loads";
      echo "POST /login code       : $HC_SSHKEY_CODE (want 302/303)";
      echo "session cookie (name)  : ${HC_SSHKEY_COOKIE:-<none>} (new: ${HC_SSHKEY_NEWCOOKIE:-<none>})";
      echo "challenge nonce        : ${HC_SSHKEY_NONCE:-<none>}";
      echo "authed GET / final code: $final ; editor markers: $markers (want >=1)";
      echo "(the private key + signature are NEVER written to evidence — §11.4.10)"; } > "$ev"
    if { [ "$HC_SSHKEY_CODE" = 302 ] || [ "$HC_SSHKEY_CODE" = 303 ]; } && [ -n "$HC_SSHKEY_COOKIE" ] \
       && [ "$final" = 200 ] && [ "$markers" -ge 1 ]; then
      ab_pass_with_evidence "HCA-QA-004: valid ssh-key login -> $HC_SSHKEY_CODE + cookie + editor loads (200)" "$ev"
    else
      ab_fail "HCA-QA-004: login journey incomplete (code=$HC_SSHKEY_CODE cookie=${HC_SSHKEY_COOKIE:-none} final=$final markers=$markers) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    { echo "hc_sshkey_login failed WITH an authorized key present";
      echo "POST /login code=$HC_SSHKEY_CODE cookie=${HC_SSHKEY_COOKIE:-none} nonce=${HC_SSHKEY_NONCE:-none}"; } > "$ev"
    ab_fail "HCA-QA-004: authorized ssh-key login did not yield a session cookie (code=$HC_SSHKEY_CODE) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "no authorized test key (HELIX_TEST_SSH_KEY unset/unreadable) — a valid-login PASS requires";
    echo "a key in the gate's allowed_signers. SKIP-with-reason, never a faked pass (§11.4/§11.4.69);";
    echo "binds at conductor live-validation when the key is provided (§11.4.98)."; } > "$ev"
  ab_skip_with_reason "HCA-QA-004 valid login: no authorized test key (HELIX_TEST_SSH_KEY)" credential_absent
fi

# =========================================================================
# HCA-QA-UI-001 real in-browser editor interaction — honest operator_attended SKIP
# =========================================================================
h_head "HCA-QA-UI-001 in-browser editing (operator_attended)"
ab_skip_with_reason "HCA-QA-UI-001 in-browser typing/file-tree after ssh-key login (needs browser-automation adapter; tracked HCA-QA-UI-001)" operator_attended

h_summary
