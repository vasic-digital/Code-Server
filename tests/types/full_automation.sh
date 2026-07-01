#!/usr/bin/env bash
# tests/types/full_automation.sh — HelixCode FULL-AUTOMATION suite (§11.4.169).
#
# Purpose:      Prove the login journey is FULLY autonomous (no manual step after
#               start, §11.4.98) AND deterministic: the same journey is run N=3
#               consecutive times with self-cleaning state each iteration, and
#               every iteration MUST produce the IDENTICAL verdict (§11.4.50).
#               A divergent iteration is an auto-FAIL — there is no "first pass
#               therefore a flake" path.
# Journey/iter: correct-pw -> 302 + session cookie; wrong-pw (per-iter-unique) ->
#               200 + no cookie; authenticated GET / -> editor Location + 200.
#               Compacted to a single verdict string; all 3 hashes must match.
# Usage:        bash tests/types/full_automation.sh
#               HC_FA_ITERS=5 bash tests/types/full_automation.sh   # override N
# Inputs:       deploy/.env via the fixture; password read from fixture, NEVER
#               printed or written to evidence (§11.4.10).
# Outputs:      per-run evidence under qa-results/tests/full_automation/<run-id>/
#               (iteration_N.txt + determinism.txt)
# Side-effects: on-demand stack boot only; per-iteration cookie jars are removed
#               (self-cleaning); the shared stack is never mutated.
# Dependencies: bash, curl, podman|docker, sha256sum|shasum
# Cross-references: §11.4.98 §11.4.50 §11.4.69 §11.4.107 §11.4.10 ; harness.sh stack_fixture.sh
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init full_automation

ITERS="${HC_FA_ITERS:-3}"

if ! h_require podman && ! h_require docker; then
  ab_skip_with_reason "full-automation suite (no container runtime on PATH)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi

_hash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

# run_journey <iteration-index> <evidence-file> -> writes evidence, echoes verdict
run_journey() {
  local i="$1" out="$2" nonce jar wjar body
  nonce="${H_RUNID}-i${i}-$RANDOM"
  jar="$(mktemp "${TMPDIR:-/tmp}/hc_fa_jar.XXXXXX")"
  wjar="$(mktemp "${TMPDIR:-/tmp}/hc_fa_wjar.XXXXXX")"
  body="$(mktemp "${TMPDIR:-/tmp}/hc_fa_body.XXXXXX")"

  local code_ok cookie code_bad bad_cookie authed_loc authed_final markers
  code_ok="$(curl -k -s -c "$jar" -o /dev/null -w '%{http_code}' --max-time 15 \
    --data-urlencode "password=${HC_PASSWORD}" "$HC_BASE/login" 2>/dev/null || echo 000)"
  cookie="$(awk 'NF && $1!~/^#/ {print $6}' "$jar" 2>/dev/null | grep -c 'code-server-session')"
  code_bad="$(curl -k -s -c "$wjar" -o /dev/null -w '%{http_code}' --max-time 15 \
    --data-urlencode "password=wrong-${nonce}" "$HC_BASE/login" 2>/dev/null || echo 000)"
  bad_cookie="$(awk 'NF && $1!~/^#/ {print $6}' "$wjar" 2>/dev/null | grep -c 'code-server-session')"
  authed_loc="$(curl -k -s -b "$jar" -D - -o /dev/null --max-time 15 "$HC_BASE/" 2>/dev/null \
    | sed -nE 's/^[Ll]ocation:[[:space:]]*//p' | tr -d '\r')"
  authed_final="$(curl -k -s -b "$jar" -L -o "$body" -w '%{http_code}' --max-time 20 "$HC_BASE/" 2>/dev/null || echo 000)"
  markers="$(grep -icE 'workbench|code-server|vscode' "$body" 2>/dev/null || true)"; markers="${markers:-0}"

  # normalize the authed-location to a stable token (editor vs login) so the
  # verdict is deterministic across runs (the folder path itself is stable here,
  # but reduce to a class token to be robust).
  local loc_class="other"
  echo "$authed_loc" | grep -q 'folder' && loc_class="editor"
  echo "$authed_loc" | grep -q 'login'  && loc_class="login"
  local marker_class="none"; [ "${markers:-0}" -ge 1 ] && marker_class="present"

  local verdict="correct=${code_ok};cookie=${cookie};wrong=${code_bad};wrong_cookie=${bad_cookie};authed_loc=${loc_class};authed_final=${authed_final};editor=${marker_class}"
  { echo "iteration: $i"; echo "nonce: $nonce"; echo "verdict: $verdict"; } > "$out"

  rm -f "$jar" "$wjar" "$body" 2>/dev/null || true   # self-cleaning state
  echo "$verdict"
}

h_head "N=$ITERS autonomous journey iterations (must be identical)"
EXPECTED="correct=302;cookie=1;wrong=200;wrong_cookie=0;authed_loc=editor;authed_final=200;editor=present"
verdicts=""
i=1
while [ "$i" -le "$ITERS" ]; do
  vev="$(h_ev "iteration_$i")"
  v="$(run_journey "$i" "$vev")"
  h_log "iter $i verdict: $v"
  verdicts="${verdicts}${v}\n"
  i=$((i+1))
done

det="$(h_ev determinism)"
uniq_count="$(printf '%b' "$verdicts" | grep -c . | tr -dc '0-9')"   # non-empty lines
distinct="$(printf '%b' "$verdicts" | sort -u | grep -c . )"
first="$(printf '%b' "$verdicts" | grep -m1 . )"
{ echo "iterations run: $ITERS"
  echo "distinct verdicts: $distinct (want 1)"
  echo "expected verdict : $EXPECTED"
  echo "observed verdict : $first"
  echo "--- all verdicts ---"; printf '%b' "$verdicts"; } > "$det"

if [ "$distinct" = 1 ] && [ "$first" = "$EXPECTED" ]; then
  ab_pass_with_evidence "journey PASSES identically across $ITERS autonomous iterations (deterministic, §11.4.50)" "$det"
else
  ab_fail "non-deterministic or wrong verdict across iterations (distinct=$distinct first='$first') [ev: ${det#$HC_ROOT/}]"
fi

h_summary
