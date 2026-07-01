#!/usr/bin/env bash
#
# tests/types/helixqa.sh — §11.4.169 HelixQA layer for HelixCode.
#
# Runs the project HelixQA bank tests/banks/helixcode-helixqa.yaml as an
# AUTONOMOUS QA session: every autonomously-HTTP-drivable case is executed live
# with captured positive evidence (§11.4.69); the case that needs a real
# in-browser editor interaction (HC-QA-UI-001) is honestly SKIPPED
# operator_attended per §11.4.3/§11.4.52 (tracked follow-up: wire a browser-
# automation adapter) — never a faked UI pass.
#
# §1.1 paired mutation: make HC-QA-002 accept wrong-pw 302, or HC-QA-UI-001
# emit a PASS without a browser -> the honest-skip/assert invariant FAILs.
#
# Cross-refs: §11.4.169 §11.4.27 §11.4.52 §11.4.3 §11.4.69 ; tests/banks/*.yaml
set -uo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$_here/../lib/harness.sh"
. "$_here/../lib/stack_fixture.sh"

h_init helixqa
BANK="$HC_ROOT/tests/banks/helixcode-helixqa.yaml"
[ -f "$BANK" ] && h_log "bank: ${BANK#$HC_ROOT/}"

# §11.4.1 / §11.4.90 — SUPERSEDED. This bank (HC-QA-002 CODE_SERVER_PASSWORD login,
# HC-QA-003/004 in-container exec) validates the RETIRED containerized-password
# model; on the 2026-07-01 host-native SSH-key auth-pivot stack it is superseded by
# helixqa_auth (tests/banks/helixcode-auth-helixqa.yaml). The old model is gone, so
# these would FALSE-FAIL — SKIP-with-reason (§11.4.6 detection). Old stack runs it.
if hc_legacy_model_retired; then
  ab_skip_with_reason "helixqa suite: superseded by helixqa_auth — legacy container+password model retired (see docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md)" topology_unsupported
  h_summary; exit $?
fi

if ! hc_stack_up; then
  ab_skip_with_reason "HelixQA autonomous session (stack could not be booted)" topology_unsupported
  h_summary; exit $?
fi
NONCE="$(date -u +%s)-$$"

# HC-QA-001 TLS edge reachable
h_head "HC-QA-001 TLS edge reachable"
ev="$(h_ev qa001_edge)"; code="$(hc_https_code /)"
echo "GET / -> $code (expect non-000; 302 to login)" > "$ev"
if [ "$code" != "000" ]; then ab_pass_with_evidence "HC-QA-001: TLS edge reachable (GET / -> $code)" "$ev"
else ab_fail "HC-QA-001: edge unreachable [ev: ${ev#$HC_ROOT/}]"; fi

# HC-QA-002 Login authentication journey
h_head "HC-QA-002 login authentication journey"
ev="$(h_ev qa002_login)"
ok="$(hc_login_code "$HC_PASSWORD")"; bad="$(hc_login_code "wrong-$NONCE")"
okc="$(hc_login_headers "$HC_PASSWORD" | grep -ic 'set-cookie' || true)"
{ echo "correct=$ok (expect 302) cookie=$okc (>=1); wrong=$bad (expect 200)"; } > "$ev"
if [ "$ok" = "302" ] && [ "${okc:-0}" -ge 1 ] && [ "$bad" = "200" ]; then
  ab_pass_with_evidence "HC-QA-002: only correct password authenticates" "$ev"
else ab_fail "HC-QA-002: auth journey wrong (ok=$ok/$okc bad=$bad) [ev: ${ev#$HC_ROOT/}]"; fi

# HC-QA-003 Authenticated editor shell served
h_head "HC-QA-003 authenticated editor served"
ev="$(h_ev qa003_editor)"; jar="$(mktemp)"
curl -k -s -c "$jar" --data-urlencode "password=$HC_PASSWORD" "$HC_BASE/login" -o /dev/null 2>/dev/null || true
body="$(curl -k -s -b "$jar" -L "$HC_BASE/" 2>/dev/null | tr -d '\0')"
rm -f "$jar"
echo "authenticated GET / body length=${#body}; workbench markers:" > "$ev"
printf '%s' "$body" | grep -oiE 'code-server|workbench|Visual Studio Code|monaco' | sort -u >> "$ev" || true
if printf '%s' "$body" | grep -qiE 'code-server|workbench|Visual Studio Code|monaco'; then
  ab_pass_with_evidence "HC-QA-003: authenticated editor shell served" "$ev"
else ab_fail "HC-QA-003: editor markers absent from authenticated body [ev: ${ev#$HC_ROOT/}]"; fi

# HC-QA-004 Project files read-write
h_head "HC-QA-004 project files read-write"
ev="$(h_ev qa004_project_rw)"
proj="$(hc_cs_exec 'ls /home/coder/projects 2>/dev/null | head -1' | tr -d "\r")"
if [ -z "$proj" ]; then ab_skip_with_reason "HC-QA-004 project RW (no project mounted)" feature_disabled_by_config
else
  tok="hcqa_${NONCE}"; f="/home/coder/projects/$proj/.hcqa_$NONCE"
  r="$(hc_cs_exec "echo $tok > '$f' && cat '$f' && rm -f '$f' && echo GONE" | tr -d "\r")"
  { echo "project=$proj token=$tok"; echo "$r"; } > "$ev"
  if printf '%s' "$r" | grep -q "$tok" && printf '%s' "$r" | grep -q GONE; then
    ab_pass_with_evidence "HC-QA-004: project files read-write (token round-trip)" "$ev"
  else ab_fail "HC-QA-004: project RW failed ($r) [ev: ${ev#$HC_ROOT/}]"; fi
fi

# HC-QA-UI-001 real in-browser editor interaction — honest operator_attended SKIP
h_head "HC-QA-UI-001 in-browser editing (operator_attended)"
ab_skip_with_reason "HC-QA-UI-001 in-browser typing/file-tree (needs browser-automation adapter; tracked HC-QA-UI-001)" operator_attended

h_summary
