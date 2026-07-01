#!/usr/bin/env bash
#
# tests/types/login_ui_auth.sh — §11.4.169 UI suite for the login-form copy/paste
# clipboard feature (copy-the-sign-command + copy-the-challenge + paste-and-
# recognize-an-armored-SSH-signature, with a multi-match picker).
#
# Orchestrates three anti-bluff layers, each citing captured evidence (§11.4.69):
#   (L1) SERVED-PAGE  — the LIVE edge /login carries both copy buttons, the paste
#        button, the inlined recognizer JS, AND a <form> (progressive enhancement:
#        the page still works with JavaScript off). The in-process Go equivalent is
#        services/auth_gate/server_login_ui_test.go.
#   (L2) RECOGNITION UNIT — node runs tests/types/login_recognition.test.js against
#        the SAME recognizer module the page inlines (1 vs many vs none vs noisy).
#   (L3) §11.4.170 HOST-RENDERED VISUAL + CLIPBOARD PROOF — login_visual_cdp.mjs
#        renders the real /login in headless Chromium (CDP), asserts both icon
#        buttons render / are labelled / on-screen / non-overlapping (§11.4.162),
#        drives copy→clipboard, paste→fill, two-signatures→picker, proves the paste
#        path is XSS-safe and never auto-submits. rc 2 = Chromium absent (honest
#        SKIP), rc 1 = a real visual/interaction defect.
#
# Usage        : RED_MODE=0 bash tests/types/login_ui_auth.sh
# Inputs       : HC_BASE (edge URL; default https://127.0.0.1:52443), RED_MODE
# Outputs      : qa-results/tests/login_ui_auth/<run-id>/ evidence (incl. PNGs)
# Side-effects : none on the git tree; a throwaway mktemp dir, trap-removed
# Dependencies : bash, curl, node (unit + CDP), chromium (visual — else SKIP)
# Cross-refs   : §11.4.162 §11.4.169 §11.4.170 §11.4.69 §11.4.107 ; harness.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# HC_BASE from the stack fixture if present, else the local edge default.
# shellcheck source=../lib/stack_fixture.sh
[ -f "$_here/../lib/stack_fixture.sh" ] && . "$_here/../lib/stack_fixture.sh" 2>/dev/null || true
HC_BASE="${HC_BASE:-https://127.0.0.1:52443}"

h_init login_ui_auth

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_login_ui.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

html="$WORK/login.html"

# ---- (L1) served-page: the live /login carries the enhancement ------------
h_head "(L1) live /login carries the copy/paste buttons + inlined recognizer (+ <form> for no-JS)"
ev="$(h_ev l1_served_page)"
code="$(curl -sk --max-time 15 "$HC_BASE/login" -o "$html" -w '%{http_code}' 2>/dev/null || echo 000)"
{ echo "assert: GET $HC_BASE/login (code=$code) contains both copy buttons, the paste button,";
  echo "        the sign-command element, the recognizer JS, and a <form> (progressive enhancement)";
  echo "--- markers ---"; } > "$ev"
if [ "$code" != 200 ]; then
  cat "$html" >> "$ev" 2>/dev/null || true
  ab_skip_with_reason "live /login UI checks (edge unreachable: HTTP $code — stack down)" "topology_unsupported"
else
  missing=0
  for m in 'id="copy-cmd-btn"' 'id="copy-challenge-btn"' 'id="paste-sig-btn"' 'id="sign-command"' 'recognizeSignatures' '<form'; do
    if grep -qF "$m" "$html" 2>/dev/null; then echo "present: $m" >> "$ev"; else echo "MISSING: $m" >> "$ev"; missing=$((missing+1)); fi
  done
  # accessibility: every icon button carries an aria-label (§11.4.170 label oracle)
  arias="$(grep -oE 'aria-label="[^"]+"' "$html" 2>/dev/null | wc -l | tr -d ' ')"
  echo "aria-label count: $arias" >> "$ev"
  if [ "$missing" -eq 0 ] && [ "${arias:-0}" -ge 3 ]; then
    ab_pass_with_evidence "live /login carries both copy buttons + paste button + recognizer + <form> + >=3 aria-labels" "$ev"
  else
    ab_fail "live /login missing $missing marker(s) / aria-labels=$arias (<3) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# ---- (L2) recognition unit test (node, stack-independent) ------------------
h_head "(L2) node recognition unit — armored-signature recognizer (1 / many / none / noisy)"
ev="$(h_ev l2_node_unit)"
if h_require node; then
  if node "$_here/login_recognition.test.js" > "$ev" 2>&1; then
    ab_pass_with_evidence "recognition unit test all cases pass ($(grep -oE '# pass [0-9]+' "$ev" | head -1))" "$ev"
  else
    ab_fail "recognition unit test FAILED [ev: ${ev#$HC_ROOT/}]"
  fi
else
  ab_skip_with_reason "recognition unit test (node not present)" "topology_unsupported"
fi

# ---- (L3) §11.4.170 host-rendered visual + clipboard-interaction proof -----
h_head "(L3) §11.4.170 host-rendered pixel proof + clipboard flow (headless Chromium via CDP)"
ev="$(h_ev l3_visual)"; vdir="$HC_EV_DIR/l3_visual"; mkdir -p "$vdir"
have_chrome=0
[ -n "${HELIX_CHROME:-}" ] && [ -x "${HELIX_CHROME:-}" ] && have_chrome=1
for b in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable; do [ -x "$b" ] && have_chrome=1; done
if [ ! -s "$html" ]; then
  ab_skip_with_reason "host-rendered visual proof (no served /login captured — stack down)" "topology_unsupported"
elif h_require node && [ "$have_chrome" = 1 ]; then
  rc=0; node "$_here/login_visual_cdp.mjs" --html "$html" --out "$vdir" > "$ev" 2>&1 || rc=$?
  # keep the produced PNG artifacts referenced in the evidence file
  { echo "--- visual verdict ---"; grep -E 'VERDICT_JSON' "$ev" 2>/dev/null | tail -1; ls -1 "$vdir" 2>/dev/null | sed 's/^/artifact: /'; } >> "$ev"
  if [ "$rc" -eq 0 ]; then
    ab_pass_with_evidence "buttons render on-screen + labelled + non-overlapping; copy->clipboard, paste->fill, 2-sig->picker; XSS-safe; no auto-submit" "$ev"
  elif [ "$rc" -eq 2 ]; then
    ab_skip_with_reason "host-rendered visual proof (Chromium unavailable at runtime)" "topology_unsupported"
  else
    ab_fail "host-rendered visual/interaction defect (rc=$rc) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  ab_skip_with_reason "host-rendered visual proof (node/Chromium not present)" "topology_unsupported"
fi

h_summary
