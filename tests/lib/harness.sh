#!/usr/bin/env bash
#
# tests/lib/harness.sh — shared ANTI-BLUFF test harness for HelixCode.
#
# Sourced by every per-test-type suite under tests/types/*.sh. Provides the
# §11.4.69 positive-evidence discipline for a host/HTTP/container stack (the
# project's challenges/lib/anti_bluff.sh is Android/on-device only and is NOT
# reusable here).
#
# Core rule (§11.4 / §11.4.69): a PASS is valid ONLY when it cites a captured,
# NON-EMPTY evidence artifact. `ab_pass_with_evidence <desc> <path>` enforces
# this mechanically — a PASS whose evidence file is missing/empty is converted
# to a FAIL. Bare "no error" is never a PASS.
#
# Polarity (§11.4.115): RED_MODE=1 flips a suite into defect-reproduction mode
# where supported; RED_MODE=0 (default) is the standing GREEN guard.
#
# Usage:
#   . "$(dirname "$0")/../lib/harness.sh"
#   h_init security
#   ev="$(h_ev tls_handshake)"; openssl ... > "$ev" 2>&1
#   ab_pass_with_evidence "TLS handshake negotiated" "$ev"
#   h_summary   # exit non-zero on any FAIL or evidence-less PASS
#
# Purpose      : anti-bluff assertion + evidence-capture helpers
# Inputs       : RED_MODE (0|1), HC_EVIDENCE_ROOT (optional override)
# Outputs      : per-run evidence dir under qa-results/tests/<suite>/<run-id>/
# Side-effects : creates evidence files; never mutates the git working tree
# Dependencies : bash, coreutils, date; callers add curl/openssl/podman
# Cross-refs   : §11.4.5 §11.4.69 §11.4.107 §11.4.115 §11.4.50 ; stack_fixture.sh
set -uo pipefail

# ---- repo root -----------------------------------------------------------
if _rr="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_rr" ]; then
  HC_ROOT="$_rr"
else
  HC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
fi
export HC_ROOT

RED_MODE="${RED_MODE:-0}"
HC_SUITE=""
HC_EVIDENCE_ROOT="${HC_EVIDENCE_ROOT:-$HC_ROOT/qa-results/tests}"
HC_EV_DIR=""
H_PASS=0; H_FAIL=0; H_SKIP=0; H_RUNID=""

# ---- init ----------------------------------------------------------------
h_init() {
  HC_SUITE="${1:-$(basename "${0%.sh}")}"
  # deterministic-ish run id: date + pid (Date.now unavailable in workflows only)
  H_RUNID="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)-$$"
  HC_EV_DIR="$HC_EVIDENCE_ROOT/$HC_SUITE/$H_RUNID"
  mkdir -p "$HC_EV_DIR"
  H_PASS=0; H_FAIL=0; H_SKIP=0
  echo "=== HelixCode suite: $HC_SUITE (RED_MODE=$RED_MODE) ==="
  echo "evidence: $HC_EV_DIR"
}

# ---- evidence path allocator --------------------------------------------
# h_ev <slug> -> prints a path under the run's evidence dir (does not create).
h_ev() { printf '%s/%s.txt\n' "$HC_EV_DIR" "${1:-evidence}"; }

# ---- logging -------------------------------------------------------------
h_log()  { echo "  $*"; }
h_head() { echo "--- $* ---"; }

# ---- PASS with mandatory evidence (§11.4.69) -----------------------------
# ab_pass_with_evidence <description> <evidence_path>
ab_pass_with_evidence() {
  local desc="$1" ev="${2:-}"
  if [ -z "$ev" ] || [ ! -f "$ev" ] || [ ! -s "$ev" ]; then
    H_FAIL=$((H_FAIL+1))
    echo "FAIL: $desc — PASS claimed WITHOUT non-empty evidence (§11.4.69 bluff) [ev='${ev:-none}']"
    return 1
  fi
  H_PASS=$((H_PASS+1))
  echo "PASS: $desc [evidence: ${ev#$HC_ROOT/}]"
  return 0
}

# ab_skip_with_reason <description> <closed-set-reason>
# reasons: hardware_not_present topology_unsupported network_unreachable_external
#          feature_disabled_by_config operator_attended credential_absent
ab_skip_with_reason() {
  local desc="$1" reason="${2:-topology_unsupported}"
  case "$reason" in
    hardware_not_present|topology_unsupported|network_unreachable_external|feature_disabled_by_config|operator_attended|credential_absent) : ;;
    *) echo "FAIL: $desc — invalid SKIP reason '$reason' (§11.4.69 closed set)"; H_FAIL=$((H_FAIL+1)); return 1 ;;
  esac
  H_SKIP=$((H_SKIP+1))
  echo "SKIP: $desc ($reason)"
  return 0
}

ab_fail() { H_FAIL=$((H_FAIL+1)); echo "FAIL: $*"; return 1; }

# ---- generic assert-with-evidence ---------------------------------------
# h_assert_eq <desc> <expected> <actual> <evidence_path>
h_assert_eq() {
  local desc="$1" exp="$2" act="$3" ev="$4"
  { echo "assert: $desc"; echo "expected: $exp"; echo "actual  : $act"; } > "$ev"
  if [ "$exp" = "$act" ]; then ab_pass_with_evidence "$desc (=$act)" "$ev"; else ab_fail "$desc: expected '$exp' got '$act' [ev: ${ev#$HC_ROOT/}]"; fi
}

# h_assert_ge <desc> <min> <actual> <evidence_path>
h_assert_ge() {
  local desc="$1" min="$2" act="$3" ev="$4"
  { echo "assert >= : $desc"; echo "min   : $min"; echo "actual: $act"; } > "$ev"
  if [ "${act:-0}" -ge "$min" ] 2>/dev/null; then ab_pass_with_evidence "$desc ($act>=$min)" "$ev"; else ab_fail "$desc: $act < $min [ev: ${ev#$HC_ROOT/}]"; fi
}

h_require() { command -v "$1" >/dev/null 2>&1; }

# ---- summary -------------------------------------------------------------
h_summary() {
  local total=$((H_PASS+H_FAIL+H_SKIP))
  echo "=== SUMMARY $HC_SUITE: PASS=$H_PASS FAIL=$H_FAIL SKIP=$H_SKIP TOTAL=$total ==="
  echo "evidence-dir: ${HC_EV_DIR#$HC_ROOT/}"
  if [ "$H_FAIL" -eq 0 ] && [ "$H_PASS" -eq 0 ] && [ "$H_SKIP" -eq 0 ]; then
    echo "FAIL: suite recorded zero assertions (§11.4 empty-suite bluff)"; return 1
  fi
  [ "$H_FAIL" -eq 0 ]
}
