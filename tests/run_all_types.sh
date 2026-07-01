#!/usr/bin/env bash
#
# tests/run_all_types.sh — run the full §11.4.169 test-type matrix and aggregate.
#
# Executes every suite under tests/types/*.sh in RISK-DESCENDING order
# (§11.4.132: most-recently-worked / most-problematic / highest-crash first),
# capturing each suite's output as evidence and producing one aggregate verdict.
# This is the authoritative serial executor (§11.4.119 single-owner) the
# main stream runs against the live installed stack.
#
# Usage:
#   bash tests/run_all_types.sh              # all suites, risk-descending
#   bash tests/run_all_types.sh --list       # list discovered suites + order
#   SUITES="security e2e" bash tests/run_all_types.sh   # subset (space list)
#
# Exit 0 iff every executed suite PASSed (exit 0). Any FAIL -> non-zero.
#
# Purpose      : aggregate all per-type suites into one release-gate verdict
# Inputs       : tests/types/*.sh ; optional SUITES= override ; RED_MODE
# Outputs      : qa-results/run_all/<run-id>/<suite>.log + summary.txt
# Side-effects : runs the suites (some drive the live stack); no repo mutation
# Cross-refs   : §11.4.132 §11.4.169 §11.4.119 §11.4.40 ; tests/lib/*
set -uo pipefail

if RR="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$RR" ]; then cd "$RR"; else
  cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"; fi

TYPES_DIR="tests/types"
RUNID="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)-$$"
OUT="qa-results/run_all/$RUNID"; mkdir -p "$OUT"

# Risk-descending order (§11.4.132). Newest/most-fragile first; foundational
# unit last. Any suite present on disk but absent here is appended (still run).
ORDER=(
  security_auth     # NEWEST surface: ssh-key auth gate (auth pivot) — highest change-risk + auth blast radius
  e2e_auth          # NEWEST surface: ssh-key login journey (challenge-response)
  extensions_auth   # NEW surface: code-server extension (plugin) install + use from the Open VSX marketplace
  tls_letsencrypt   # Let's Encrypt TLS edge — high change-risk
  security          # legacy auth/TLS/secret-leak — highest blast radius
  stress_chaos      # failure-injection / recovery
  integration       # real wiring
  e2e               # user journey
  full_automation   # re-runnable journey (determinism)
  concurrency       # atomicity under contention
  race              # deadlock / race patterns
  load              # DDoS / flood resilience
  memory            # RSS soak / §12.6
  benchmark         # latency vs baseline
  unit              # foundational logic (fast, run last per risk-order)
)

# Discover suites actually present.
declare -A HAVE=()
for f in "$TYPES_DIR"/*.sh; do [ -e "$f" ] || continue; HAVE["$(basename "${f%.sh}")"]=1; done

# Build the run list: ORDER first (if present), then any extras, filtered by SUITES.
run_list=()
for s in "${ORDER[@]}"; do [ "${HAVE[$s]:-}" = 1 ] && run_list+=("$s"); done
for s in "${!HAVE[@]}"; do
  case " ${ORDER[*]} " in *" $s "*) : ;; *) run_list+=("$s") ;; esac
done
if [ -n "${SUITES:-}" ]; then
  filtered=(); for s in "${run_list[@]}"; do case " $SUITES " in *" $s "*) filtered+=("$s");; esac; done
  run_list=("${filtered[@]}")
fi

if [ "${1:-}" = "--list" ]; then
  printf 'discovered %d suites; run order (risk-descending §11.4.132):\n' "${#run_list[@]}"
  printf '  %s\n' "${run_list[@]}"; exit 0
fi

echo "=== HelixCode full test-type matrix (§11.4.169) — run $RUNID ==="
echo "suites: ${run_list[*]:-<none>}"
[ "${#run_list[@]}" -gt 0 ] || { echo "FAIL: no suites found under $TYPES_DIR"; exit 1; }

pass=0; fail=0; failed=()
summary="$OUT/summary.txt"; : > "$summary"
for s in "${run_list[@]}"; do
  log="$OUT/$s.log"
  echo "--- running $s ---"
  if RED_MODE=0 bash "$TYPES_DIR/$s.sh" >"$log" 2>&1; then
    verdict=PASS; pass=$((pass+1))
  else
    verdict=FAIL; fail=$((fail+1)); failed+=("$s")
  fi
  # surface each suite's own SUMMARY line for the aggregate
  sline="$(grep -E '=== SUMMARY' "$log" | tail -1)"
  printf '%-18s %s   %s\n' "$s" "$verdict" "${sline:-}" | tee -a "$summary"
done

echo "=== AGGREGATE: PASS=$pass FAIL=$fail  (evidence: $OUT) ==="
[ "$fail" -eq 0 ] || { echo "FAILED suites: ${failed[*]}"; exit 1; }
echo "PASS: full §11.4.169 test-type matrix green"
