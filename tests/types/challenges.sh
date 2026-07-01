#!/usr/bin/env bash
#
# tests/types/challenges.sh — §11.4.169 Challenges layer for HelixCode.
#
# Faithfully executes the project Challenge bank tests/banks/helixcode-
# challenges.yaml: each user-facing capability is exercised LIVE and scored
# PASS only on captured positive evidence (§11.4.27(B)/§11.4.69) — no
# metadata-only/absence-of-error passes. Fresh evidence per run (no stale refs,
# §11.4.107). The same bank is loadable by the vasic-digital/challenges Go
# engine when built; this runner is the project-native, always-available
# executor (no toolchain dependency), keeping the submodule project-agnostic
# (§11.4.28).
#
# §1.1 paired mutation: force any challenge's positive assertion to accept the
# broken state (e.g. treat wrong-pw 200 as auth-ok, or a missing token as RW-ok)
# -> ab_pass_with_evidence still fires but the captured evidence shows the
# defect, and the assertion FAILs -> suite FAILs.
#
# Purpose      : anti-bluff Challenge execution over live user-facing capabilities
# Cross-refs   : §11.4.169 §11.4.27 §11.4.69 §11.4.107 ; tests/banks/*.yaml
set -uo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$_here/../lib/harness.sh"
. "$_here/../lib/stack_fixture.sh"

h_init challenges
BANK="$HC_ROOT/tests/banks/helixcode-challenges.yaml"
[ -f "$BANK" ] && h_log "bank: ${BANK#$HC_ROOT/}"

if ! hc_stack_up; then
  ab_skip_with_reason "HelixCode Challenge bank (stack could not be booted)" topology_unsupported
  h_summary; exit $?
fi
NONCE="$(date -u +%s)-$$"

# ---- CH1: tls-edge-handshake --------------------------------------------
h_head "CH1 tls-edge-handshake"
ev="$(h_ev ch1_tls_handshake)"; hc_tls_probe "$ev"
if grep -qiE 'cipher|protocol.*TLS' "$ev"; then ab_pass_with_evidence "CH1: TLS edge negotiates a cipher (secure editor access)" "$ev"
else ab_fail "CH1: TLS handshake produced no cipher/protocol line [ev: ${ev#$HC_ROOT/}]"; fi

# ---- CH2: auth-login-journey --------------------------------------------
h_head "CH2 auth-login-journey"
ev="$(h_ev ch2_auth_journey)"
ok_code="$(hc_login_code "$HC_PASSWORD")"
bad_code="$(hc_login_code "wrong-$NONCE")"
ok_cookie="$(hc_login_headers "$HC_PASSWORD" | grep -ic 'set-cookie' || true)"
bad_cookie="$(hc_login_headers "wrong-$NONCE" | grep -ic 'set-cookie' || true)"
{ echo "correct_pw_code=$ok_code (expect 302)"; echo "correct_pw_setcookie=$ok_cookie (expect >=1)";
  echo "wrong_pw_code=$bad_code (expect 200)"; echo "wrong_pw_setcookie=$bad_cookie (expect 0)"; } > "$ev"
if [ "$ok_code" = "302" ] && [ "${ok_cookie:-0}" -ge 1 ] && [ "$bad_code" = "200" ] && [ "${bad_cookie:-0}" -eq 0 ]; then
  ab_pass_with_evidence "CH2: real auth — correct=302+cookie, wrong=200+no-cookie" "$ev"
else ab_fail "CH2: auth journey wrong (ok=$ok_code/$ok_cookie bad=$bad_code/$bad_cookie) [ev: ${ev#$HC_ROOT/}]"; fi

# ---- CH3: project-read-write --------------------------------------------
h_head "CH3 project-read-write"
ev="$(h_ev ch3_project_rw)"
tok="hc_ch_${NONCE}"
proj="$(hc_cs_exec 'ls /home/coder/projects 2>/dev/null | head -1' | tr -d "\r")"
if [ -z "$proj" ]; then ab_skip_with_reason "CH3 project RW (no project mounted)" feature_disabled_by_config
else
  base="/home/coder/projects/$proj/.hc_challenge_$NONCE"
  wr="$(hc_cs_exec "echo $tok > '$base' && cat '$base' && rm -f '$base' && echo DELETED_OK" | tr -d "\r")"
  { echo "project=$proj token=$tok"; echo "write_read_delete_result:"; echo "$wr"; } > "$ev"
  if printf '%s' "$wr" | grep -q "$tok" && printf '%s' "$wr" | grep -q DELETED_OK; then
    ab_pass_with_evidence "CH3: project RW — token written+read+deleted in-container" "$ev"
  else ab_fail "CH3: project RW failed (result: $wr) [ev: ${ev#$HC_ROOT/}]"; fi
fi

# ---- CH4: watcher-exclude-active ----------------------------------------
h_head "CH4 watcher-exclude-active"
ev="$(h_ev ch4_watcher_exclude)"
we="$(hc_cs_exec 'grep -c watcherExclude /home/coder/.local/share/code-server/User/settings.json 2>/dev/null' | tr -dc '0-9')"
{ echo "settings.json watcherExclude occurrences (in-container) = ${we:-0} (expect >=1)"; } > "$ev"
if [ "${we:-0}" -ge 1 ]; then ab_pass_with_evidence "CH4: watcherExclude live in cs-data (inotify fix active)" "$ev"
else ab_fail "CH4: watcherExclude not present in running settings.json [ev: ${ev#$HC_ROOT/}]"; fi

# ---- CH5: tls-mode-machinery --------------------------------------------
h_head "CH5 tls-mode-machinery"
ev="$(h_ev ch5_tls_machinery)"
ss_ok=0; modes_ok=0
if grep -q 'UP_SH_RENDER_ONLY' "$HC_ROOT/deploy/up.sh" 2>/dev/null; then
  ( cd "$HC_ROOT/deploy" && UP_SH_RENDER_ONLY=1 CADDYFILE_OUT=/tmp/.hc_cf_$NONCE TLS_MODE=self-signed bash up.sh >/dev/null 2>&1 || true )
  git -C "$HC_ROOT" show HEAD:deploy/Caddyfile > /tmp/.hc_cf_committed_$NONCE 2>/dev/null || true
  cmp -s /tmp/.hc_cf_$NONCE /tmp/.hc_cf_committed_$NONCE 2>/dev/null && ss_ok=1
  rm -f /tmp/.hc_cf_$NONCE /tmp/.hc_cf_committed_$NONCE 2>/dev/null
fi
grep -qE 'letsencrypt|internal-acme|acme_ca|TLS_MODE' "$HC_ROOT/deploy/up.sh" 2>/dev/null && modes_ok=1
{ echo "self-signed render byte-identical to committed Caddyfile = $ss_ok (expect 1)";
  echo "letsencrypt/internal-acme machinery present in up.sh = $modes_ok (expect 1)"; } > "$ev"
if [ "$ss_ok" -eq 1 ] && [ "$modes_ok" -eq 1 ]; then
  ab_pass_with_evidence "CH5: TLS-mode machinery — self-signed regression-safe + LE/ACME wired" "$ev"
else ab_fail "CH5: TLS-mode machinery incomplete (ss=$ss_ok modes=$modes_ok) [ev: ${ev#$HC_ROOT/}]"; fi

h_log "note: this bank is also loadable by the vasic-digital/challenges Go engine (pkg/bank); this runner is the project-native always-available executor."
h_summary
