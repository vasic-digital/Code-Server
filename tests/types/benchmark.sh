#!/usr/bin/env bash
# tests/types/benchmark.sh — HelixCode BENCHMARK / PERFORMANCE suite
#                            (§11.4.169 benchmarking/performance).
#
# Purpose:      Measure the latency distribution (p50/p95/p99) of the two hot
#               user-facing operations through Caddy and record a regression
#               baseline, with REAL captured evidence:
#                 (B1) login-page latency  — GET /login (200), N samples.
#                 (B2) authenticated-op latency — POST /login with the correct
#                      password -> 302 + session (credential verify + mint), N
#                      samples. The password is read from the fixture and is
#                      NEVER written to evidence (§11.4.10) — only timings/codes.
#                 (B3) stack startup time — measured ONLY when this suite itself
#                      cold-boots a down stack (the sanctioned on-demand path);
#                      when the shared stack is ALREADY up, a real cold-start is
#                      unmeasurable without stopping it (§11.4.119) -> honest SKIP,
#                      with read-only uptime recorded as context.
#               First run writes tests/types/.benchmark_baseline.env and does NOT
#               hard-fail (nothing to compare). Subsequent runs assert current p95
#               <= baseline p95 * (1 + TOL) and record the delta.
# Usage:        bash tests/types/benchmark.sh
#               HC_BENCH_N=30 HC_BENCH_TOL_PCT=50 bash tests/types/benchmark.sh
# Inputs:       deploy/.env via the fixture ; tests/types/.benchmark_baseline.env
# Outputs:      per-run evidence under qa-results/tests/benchmark/<run-id>/ ;
#               tests/types/.benchmark_baseline.env (created if absent)
# Side-effects: read-only HTTP timings against the shared stack; writes the
#               baseline file on first run; never stops/reconfigures the stack.
# Dependencies: bash, curl, awk, sort
# Cross-references: §11.4.169 §11.4.24 §11.4.119 §11.4.10 §11.4.6 ; harness.sh stack_fixture.sh
#
# §1.1 PAIRED MUTATION (per case, for the meta-test sweep):
#   B1/B2 corrupt the percentile picker (e.g. always return 0ms) OR treat a 000
#         no-response as a valid sample -> the "N valid samples + sane pXX" assert
#         FAILs (a distribution built from dead responses is a bluff).
#   B3    force WAS_UP=0 with a fake instant boot -> a ~0ms startup would be
#         recorded; the guard requires a genuinely-booted stack, else SKIP.
#   REG   shrink HC_BENCH_TOL_PCT to a negative value on a subsequent run ->
#         current p95 exceeds the (now-tiny) budget -> the regression assert FAILs.
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init benchmark

# §11.4.1 / §11.4.90 — SUPERSEDED. B2 benchmarks the RETIRED CODE_SERVER_PASSWORD
# POST /login -> 302 credential-verify+mint; on the 2026-07-01 host-native SSH-key
# auth-pivot stack it is superseded by benchmark_auth. The password model is gone,
# so B2 would yield 0 valid 302 samples and FALSE-FAIL — SKIP-with-reason (§11.4.6
# detection), never a false FAIL. On the OLD stack it still runs unchanged.
if hc_legacy_model_retired; then
  ab_skip_with_reason "benchmark suite: superseded by benchmark_auth — legacy container+password model retired (see docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md)" topology_unsupported
  h_summary; exit $?
fi

N="${HC_BENCH_N:-30}"
TOL_PCT="${HC_BENCH_TOL_PCT:-50}"     # allowed p95 regression vs baseline, percent
# Absolute noise floor (ms): sub-10ms ops are jitter-dominated (observed login-page
# p95 swings 5..24ms run-to-run), so a % tolerance alone false-FAILs. A regression
# counts only when it exceeds BOTH the % budget AND baseline+ABS_FLOOR (§11.4.6 —
# calibrated on this stack's own measured jitter, not a literature constant).
ABS_FLOOR_MS="${HC_BENCH_ABS_FLOOR_MS:-25}"
BASELINE="$HC_ROOT/tests/types/.benchmark_baseline.env"

# ---- runtime guard + startup timing (B3) ---------------------------------
if ! h_require curl || ! h_require awk; then
  ab_skip_with_reason "benchmark suite (curl/awk absent)" topology_unsupported
  h_summary; exit $?
fi
hc_load_env
WAS_UP=0; hc_is_up && WAS_UP=1
STARTUP_MS=""
t0="$(date +%s.%N 2>/dev/null || echo 0)"
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi
t1="$(date +%s.%N 2>/dev/null || echo 0)"

# code-server readiness (§11.4.107(3) / §11.4.144). GET /login==200 is the real
# upstream signal (Caddy /healthz stays 200 during a restart). Tolerate a
# transient restart of the SHARED single-owner stack (§11.4.119) without bluffing:
# wait for genuine readiness, then benchmark real responses. Measured AFTER t1 so
# it never inflates the B3 startup number.
hc_cs_ready() { [ "$(hc_https_code /login)" = 200 ]; }
hc_wait_cs()  { local i n="${1:-45}"; for i in $(seq 1 "$n"); do hc_cs_ready && return 0; sleep 2; done; return 1; }
if ! hc_wait_cs 45; then
  ab_fail "code-server upstream not serving /login=200 after ~90s — cannot benchmark real responses"
  h_summary; exit $?
fi

# ---- percentile helper ---------------------------------------------------
# pXX <file-of-integers-ms> <p> -> integer ms at the p-th percentile (nearest-rank)
pctl() {
  awk -v p="$2" 'NF{a[n++]=$1} END{
    if(n==0){print "NA"; exit}
    # sort
    for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
    idx=int((p/100.0)*n + 0.9999); if(idx<1)idx=1; if(idx>n)idx=n;
    print a[idx-1];
  }' "$1"
}

# ---- latency sampler -----------------------------------------------------
# bench <slug> <method GET|POSTPW> <path> <expected-code> -> prints "p50 p95 p99 valid"
bench() {
  local slug="$1" method="$2" path="$3" want="$4"
  local raw="$WORK/${slug}.raw" ms="$WORK/${slug}.ms"
  : > "$raw"; : > "$ms"
  local k=0
  while [ "$k" -lt "$N" ]; do
    k=$((k+1))
    local line code t
    if [ "$method" = POSTPW ]; then
      # password from env var, never echoed into any file (§11.4.10)
      line="$(curl -k -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 \
                --data-urlencode "password=${HC_PASSWORD}" "$HC_BASE$path" 2>/dev/null)"
    else
      line="$(curl -k -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 \
                "$HC_BASE$path" 2>/dev/null)"
    fi
    code="${line%% *}"; t="${line##* }"
    # convert seconds float -> integer ms
    local mms; mms="$(awk -v s="${t:-0}" 'BEGIN{printf "%d",(s*1000)+0.5}')"
    printf 'sample=%s code=%s ms=%s\n' "$k" "${code:-000}" "$mms" >> "$raw"
    # only count a sample toward the distribution if it is a LIVE expected response
    if [ "$code" = "$want" ]; then printf '%s\n' "$mms" >> "$ms"; fi
  done
  # `|| echo 0` would append a 2nd line when $ms is empty (grep -c prints 0 AND
  # exits 1) -> "0\n0" corrupts this return field (§11.4.1). Use `|| true` + default.
  local valid; valid="$(grep -c . "$ms" 2>/dev/null || true)"; valid="${valid:-0}"
  printf '%s %s %s %s' "$(pctl "$ms" 50)" "$(pctl "$ms" 95)" "$(pctl "$ms" 99)" "$valid"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_bench.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ==========================================================================
# B1 — login page latency  (GET /login -> 200)
# ==========================================================================
h_head "B1 — login page latency (GET /login, N=$N)"
ev="$(h_ev b1_loginpage_latency)"
read -r LP_P50 LP_P95 LP_P99 LP_VALID <<EOF
$(bench loginpage GET /login 200)
EOF
{ echo "GET /login  N=$N  expected=200"
  echo "valid_samples=$LP_VALID  p50=${LP_P50}ms  p95=${LP_P95}ms  p99=${LP_P99}ms"
  echo "--- raw ---"; cat "$WORK/loginpage.raw"; } > "$ev"
if [ "${LP_VALID:-0}" -ge "$((N/2))" ] && [ "$LP_P50" != NA ] && [ "${LP_P95:-0}" -ge 0 ] 2>/dev/null; then
  ab_pass_with_evidence "B1: login-page p50=${LP_P50}ms p95=${LP_P95}ms p99=${LP_P99}ms over $LP_VALID/$N valid samples" "$ev"
else
  ab_fail "B1: insufficient valid samples for login page ($LP_VALID/$N) [ev: ${ev#$HC_ROOT/}]"
fi

# ==========================================================================
# B2 — authenticated op latency (POST /login correct pw -> 302)
# ==========================================================================
h_head "B2 — authenticated op latency (POST /login -> 302, N=$N)"
ev="$(h_ev b2_authop_latency)"
read -r AO_P50 AO_P95 AO_P99 AO_VALID <<EOF
$(bench authop POSTPW /login 302)
EOF
{ echo "POST /login (correct password)  N=$N  expected=302  [password NEVER recorded, §11.4.10]"
  echo "valid_samples=$AO_VALID  p50=${AO_P50}ms  p95=${AO_P95}ms  p99=${AO_P99}ms"
  echo "--- raw (codes + timings only) ---"; cat "$WORK/authop.raw"; } > "$ev"
if [ "${AO_VALID:-0}" -ge "$((N/2))" ] && [ "$AO_P50" != NA ]; then
  ab_pass_with_evidence "B2: authenticated-op p50=${AO_P50}ms p95=${AO_P95}ms p99=${AO_P99}ms over $AO_VALID/$N valid 302s" "$ev"
else
  ab_fail "B2: insufficient valid 302 samples for authenticated op ($AO_VALID/$N) [ev: ${ev#$HC_ROOT/}]"
fi

# ==========================================================================
# B3 — stack startup time (only if WE cold-booted; else honest SKIP)
# ==========================================================================
h_head "B3 — stack startup time"
ev="$(h_ev b3_startup)"
if [ "$WAS_UP" -eq 0 ]; then
  STARTUP_MS="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d",((b-a)*1000)+0.5}')"
  { echo "stack was DOWN at suite entry; this suite cold-booted it via hc_stack_up (§11.4.76)"
    echo "startup_to_ready_ms=$STARTUP_MS"; } > "$ev"
  if [ "${STARTUP_MS:-0}" -gt 0 ]; then
    ab_pass_with_evidence "B3: measured cold stack startup-to-ready = ${STARTUP_MS}ms" "$ev"
  else
    ab_fail "B3: startup timing captured a non-positive interval (${STARTUP_MS}ms) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  up_cs="$("$HC_ENGINE" inspect "$HC_CS"    --format '{{.State.StartedAt}}' 2>/dev/null)"
  up_cd="$("$HC_ENGINE" inspect "$HC_CADDY" --format '{{.State.StartedAt}}' 2>/dev/null)"
  { echo "stack was ALREADY UP at suite entry — a real cold start cannot be measured"
    echo "without stopping the SHARED single-owner stack (§11.4.119). Read-only context:"
    echo "code-server StartedAt = $up_cs"
    echo "caddy       StartedAt = $up_cd"; } > "$ev"
  ab_skip_with_reason "stack startup time (stack already running; cold boot would require stopping the shared single-owner stack §11.4.119 — measured only when this suite itself boots a down stack)" feature_disabled_by_config
fi

# ==========================================================================
# Regression check vs baseline (record on first run, assert thereafter)
# ==========================================================================
h_head "regression check vs baseline"
ev="$(h_ev reg_check)"
if [ ! -f "$BASELINE" ]; then
  umask 022
  cat > "$BASELINE" <<EOF
# HelixCode benchmark baseline — auto-generated by tests/types/benchmark.sh.
# Latencies in milliseconds. Regenerate by deleting this file and re-running.
BASELINE_LOGINPAGE_P50=$LP_P50
BASELINE_LOGINPAGE_P95=$LP_P95
BASELINE_LOGINPAGE_P99=$LP_P99
BASELINE_AUTHOP_P50=$AO_P50
BASELINE_AUTHOP_P95=$AO_P95
BASELINE_AUTHOP_P99=$AO_P99
EOF
  { echo "no prior baseline — established tests/types/.benchmark_baseline.env"
    echo "loginpage p95=${LP_P95}ms  authop p95=${AO_P95}ms  tolerance=${TOL_PCT}%"; } > "$ev"
  ab_pass_with_evidence "REG: baseline established (first run — no regression to assert); loginpage p95=${LP_P95}ms authop p95=${AO_P95}ms" "$ev"
else
  # shellcheck disable=SC1090
  . "$BASELINE"
  # budget = max( baseline*(1+tol%) , baseline + ABS_FLOOR_MS )
  lp_budget="$(awk -v b="${BASELINE_LOGINPAGE_P95:-0}" -v t="$TOL_PCT" -v a="$ABS_FLOOR_MS" 'BEGIN{p=b*(100+t)/100; f=b+a; printf "%d",((p>f)?p:f)+0.5}')"
  ao_budget="$(awk -v b="${BASELINE_AUTHOP_P95:-0}"    -v t="$TOL_PCT" -v a="$ABS_FLOOR_MS" 'BEGIN{p=b*(100+t)/100; f=b+a; printf "%d",((p>f)?p:f)+0.5}')"
  { echo "baseline: loginpage_p95=${BASELINE_LOGINPAGE_P95}ms authop_p95=${BASELINE_AUTHOP_P95}ms  tolerance=${TOL_PCT}% abs_floor=${ABS_FLOOR_MS}ms"
    echo "current : loginpage_p95=${LP_P95}ms (budget=${lp_budget}ms)  authop_p95=${AO_P95}ms (budget=${ao_budget}ms)"; } > "$ev"
  lp_ok=1; ao_ok=1
  [ "${LP_P95:-0}" -le "$lp_budget" ] 2>/dev/null || lp_ok=0
  [ "${AO_P95:-0}" -le "$ao_budget" ] 2>/dev/null || ao_ok=0
  if [ "$lp_ok" -eq 1 ] && [ "$ao_ok" -eq 1 ]; then
    ab_pass_with_evidence "REG: no p95 regression beyond ${TOL_PCT}% (loginpage ${LP_P95}<=${lp_budget}, authop ${AO_P95}<=${ao_budget})" "$ev"
  else
    ab_fail "REG: p95 regression > ${TOL_PCT}% (loginpage ${LP_P95}/${lp_budget} authop ${AO_P95}/${ao_budget}) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

h_summary
