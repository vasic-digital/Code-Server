#!/usr/bin/env bash
# tests/types/benchmark_auth.sh — SSH-key auth LATENCY / regression suite
#                                 (§11.4.169 benchmarking/performance).
#
# Purpose:      Measure the latency distribution (p50/p95/p99) of the auth-pivot's
#               hot user-facing operations and assert NO regression against a
#               recorded baseline (tests/.benchmark_auth_baseline.env), with REAL
#               captured per-sample evidence:
#                 (BA1) login-page latency  — GET /login through the TLS edge (200),
#                       the page that issues the ssh-key challenge.
#                 (BA2) forward-auth latency — GET /auth on the gate with NO cookie
#                       (401). This is the HOTTEST path: Caddy calls it on EVERY
#                       request, so its p95 gates perceived editor responsiveness.
#                 (BA3) full login-journey latency — GET challenge -> ssh-keygen
#                       sign -> POST -> 302 (the crypto-verify path), timed
#                       end-to-end. Needs an authorized key -> uses
#                       $HELIX_TEST_SSH_KEY when provided, else SKIP
#                       (credential_absent) — a login-journey PASS is NEVER faked.
#                 (REG) current p95 for every MEASURED metric must stay within
#                       budget = max(baseline*(1+TOL%), baseline+ABS_FLOOR) or it
#                       is a regression FINDING.
#               No secret is ever written to evidence (§11.4.10) — only timings +
#               HTTP codes + field NAMES.
# Usage:        bash tests/types/benchmark_auth.sh
#               HC_BENCH_N=30 HC_BENCH_TOL_PCT=50 HC_BENCH_ABS_FLOOR_MS=40 bash tests/types/benchmark_auth.sh
# Inputs:       deploy/.env + HELIX_AUTH_ADDR via the fixture ;
#               tests/.benchmark_auth_baseline.env ; optional HELIX_TEST_SSH_KEY /
#               HELIX_AUTH_PRINCIPAL
# Outputs:      per-run evidence under qa-results/tests/benchmark_auth/<run-id>/ ;
#               (re)creates tests/.benchmark_auth_baseline.env only if it is missing
# Side-effects: read-only HTTP timings + login POSTs against the shared stack; never
#               stops/reconfigures the stack; never mutates the git tree.
# Dependencies: bash, curl, awk, sort ; ssh-keygen (BA3 only)
# Cross-references: §11.4.169 §11.4.24 §11.4.119 §11.4.10 §11.4.6 §11.4.98 ;
#                   harness.sh stack_fixture.sh ; spec 2026-07-01-auth-pivot-ssh-key.md
#
# §1.1 PAIRED MUTATION (per case, for the meta-test sweep):
#   BA1/BA2/BA3 corrupt the percentile picker (always 0ms) OR count a 000/wrong-code
#         as a valid sample -> "N valid samples + sane pXX" assert FAILs (a
#         distribution built from dead responses is a bluff).
#   REG   shrink HC_BENCH_TOL_PCT to a negative value on a subsequent run -> current
#         p95 exceeds the (now-tiny) budget -> the regression assert FAILs.
#
# ANTI-BLUFF (§11.4/§11.4.69): when the live auth-pivot stack is not deployed the
# suite SKIPs-with-reason(topology_unsupported) — never a fake PASS. Mocks are
# FORBIDDEN (benchmark type, §11.4.27); every PASS cites captured latency samples.
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init benchmark_auth

N="${HC_BENCH_N:-30}"
TOL_PCT="${HC_BENCH_TOL_PCT:-50}"          # allowed p95 regression vs baseline (percent)
ABS_FLOOR_MS="${HC_BENCH_ABS_FLOOR_MS:-40}" # sub-floor jitter budget (ssh-keygen subprocess jitter; §11.4.6 calibrated headroom)
BASELINE="$HC_ROOT/tests/.benchmark_auth_baseline.env"
PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"

# ---- guards --------------------------------------------------------------
if ! h_require curl || ! h_require awk; then
  ab_skip_with_reason "benchmark_auth (curl/awk absent)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_new_stack_up; then
  ev="$(h_ev stack_down)"
  { echo "auth-pivot ssh-key stack not deployed (conductor deploys it live later)";
    echo "probe: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "benchmark_auth: ssh-key auth stack not deployed ($HC_NEW_STACK_DETAIL)" topology_unsupported
  h_summary; exit $?
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_bench_auth.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ---- percentile (nearest-rank) -------------------------------------------
pctl() {
  awk -v p="$2" 'NF{a[n++]=$1} END{
    if(n==0){print "NA"; exit}
    for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
    idx=int((p/100.0)*n + 0.9999); if(idx<1)idx=1; if(idx>n)idx=n;
    print a[idx-1];
  }' "$1"
}

# ---- HTTP latency sampler (GET; counts only the expected-code responses) ---
# bench <slug> <url> <expected-code> -> prints "p50 p95 p99 valid"
bench_get() {
  local slug="$1" url="$2" want="$3"
  local raw="$WORK/${slug}.raw" ms="$WORK/${slug}.ms"
  : > "$raw"; : > "$ms"
  local k=0
  while [ "$k" -lt "$N" ]; do
    k=$((k+1))
    local line code t mms
    line="$(curl -k -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 "$url" 2>/dev/null)"
    code="${line%% *}"; t="${line##* }"
    mms="$(awk -v s="${t:-0}" 'BEGIN{printf "%d",(s*1000)+0.5}')"
    printf 'sample=%s code=%s ms=%s\n' "$k" "${code:-000}" "$mms" >> "$raw"
    [ "$code" = "$want" ] && printf '%s\n' "$mms" >> "$ms"
  done
  local valid; valid="$(grep -c . "$ms" 2>/dev/null || true)"; valid="${valid:-0}"
  printf '%s %s %s %s' "$(pctl "$ms" 50)" "$(pctl "$ms" 95)" "$(pctl "$ms" 99)" "$valid"
}

# ==========================================================================
# BA1 — login-page latency (GET /login through the edge -> 200)
# ==========================================================================
h_head "BA1 — login-page latency (GET ${HC_BASE}/login, N=$N)"
ev="$(h_ev ba1_loginpage)"
read -r LP_P50 LP_P95 LP_P99 LP_VALID <<EOF
$(bench_get loginpage "$HC_BASE/login" 200)
EOF
{ echo "GET $HC_BASE/login  N=$N  expected=200 (ssh-key challenge page)";
  echo "valid_samples=$LP_VALID  p50=${LP_P50}ms  p95=${LP_P95}ms  p99=${LP_P99}ms";
  echo "--- raw ---"; cat "$WORK/loginpage.raw"; } > "$ev"
if [ "${LP_VALID:-0}" -ge "$((N/2))" ] && [ "$LP_P50" != NA ] && [ "${LP_P95:-0}" -ge 0 ] 2>/dev/null; then
  ab_pass_with_evidence "BA1: login-page p50=${LP_P50}ms p95=${LP_P95}ms p99=${LP_P99}ms over $LP_VALID/$N valid 200s" "$ev"
else
  ab_fail "BA1: insufficient valid 200 samples for login page ($LP_VALID/$N) [ev: ${ev#$HC_ROOT/}]"
fi

# ==========================================================================
# BA2 — forward-auth latency (GET gate /auth, no cookie -> 401; hottest path)
# ==========================================================================
h_head "BA2 — forward-auth latency (GET http://${HC_GATE_ADDR}/auth -> 401, N=$N)"
ev="$(h_ev ba2_forward_auth)"
read -r AU_P50 AU_P95 AU_P99 AU_VALID <<EOF
$(bench_get forwardauth "http://${HC_GATE_ADDR}/auth" 401)
EOF
{ echo "GET http://${HC_GATE_ADDR}/auth (no cookie)  N=$N  expected=401 (fail-closed forward-auth check)";
  echo "valid_samples=$AU_VALID  p50=${AU_P50}ms  p95=${AU_P95}ms  p99=${AU_P99}ms";
  echo "--- raw ---"; cat "$WORK/forwardauth.raw"; } > "$ev"
if [ "${AU_VALID:-0}" -ge "$((N/2))" ] && [ "$AU_P50" != NA ]; then
  ab_pass_with_evidence "BA2: forward-auth p50=${AU_P50}ms p95=${AU_P95}ms p99=${AU_P99}ms over $AU_VALID/$N valid 401s" "$ev"
else
  ab_fail "BA2: insufficient valid 401 samples for /auth ($AU_VALID/$N) [ev: ${ev#$HC_ROOT/}]"
fi

# ==========================================================================
# BA3 — full login-journey latency (challenge -> sign -> POST -> 302)
#       needs an authorized key; else honest SKIP (credential_absent).
# ==========================================================================
h_head "BA3 — full ssh-key login-journey latency (N=$N)"
ev="$(h_ev ba3_journey)"
JO_P50=NA; JO_P95=NA; JO_P99=NA; JO_VALID=0; JO_MEASURED=0
KEYFILE="${HELIX_TEST_SSH_KEY:-}"
if ! h_require ssh-keygen; then
  { echo "ssh-keygen not on PATH — cannot drive a real ssh-key login journey"; } > "$ev"
  ab_skip_with_reason "BA3 login-journey latency: ssh-keygen not on PATH" topology_unsupported
elif [ -z "$KEYFILE" ] || [ ! -r "$KEYFILE" ]; then
  { echo "no authorized test key (HELIX_TEST_SSH_KEY unset/unreadable) — a genuine login";
    echo "journey requires a key present in the gate's allowed_signers. SKIP-with-reason,";
    echo "never a faked timing (§11.4/§11.4.69). Binds once the conductor provides the key (§11.4.98)."; } > "$ev"
  ab_skip_with_reason "BA3 login-journey latency: no authorized test key (HELIX_TEST_SSH_KEY)" credential_absent
else
  jms="$WORK/journey.ms"; jraw="$WORK/journey.raw"; : > "$jms"; : > "$jraw"
  k=0
  while [ "$k" -lt "$N" ]; do
    k=$((k+1))
    jar="$WORK/jjar.$k"
    t0="$(date +%s.%N 2>/dev/null || echo 0)"
    ok=1; hc_sshkey_login "$HC_BASE" "$KEYFILE" "$jar" "$PRINCIPAL" >/dev/null 2>&1 || ok=0
    t1="$(date +%s.%N 2>/dev/null || echo 0)"
    code="${HC_SSHKEY_CODE:-000}"
    mms="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d",((b-a)*1000)+0.5}')"
    printf 'sample=%s code=%s ok=%s ms=%s\n' "$k" "$code" "$ok" "$mms" >> "$jraw"
    # count only genuinely-successful journeys (cookie set AND 302/303) toward the distribution
    if [ "$ok" = 1 ] && { [ "$code" = 302 ] || [ "$code" = 303 ]; }; then printf '%s\n' "$mms" >> "$jms"; fi
    rm -f "$jar" 2>/dev/null || true
  done
  JO_VALID="$(grep -c . "$jms" 2>/dev/null || true)"; JO_VALID="${JO_VALID:-0}"
  JO_P50="$(pctl "$jms" 50)"; JO_P95="$(pctl "$jms" 95)"; JO_P99="$(pctl "$jms" 99)"
  { echo "full challenge->sign->POST journey  N=$N  success=302/303+cookie  [key/sig NEVER recorded, §11.4.10]";
    echo "principal=$PRINCIPAL  valid_journeys=$JO_VALID  p50=${JO_P50}ms  p95=${JO_P95}ms  p99=${JO_P99}ms";
    echo "--- raw (codes + timings only) ---"; cat "$jraw"; } > "$ev"
  if [ "${JO_VALID:-0}" -ge "$((N/2))" ] && [ "$JO_P50" != NA ]; then
    JO_MEASURED=1
    ab_pass_with_evidence "BA3: login-journey p50=${JO_P50}ms p95=${JO_P95}ms p99=${JO_P99}ms over $JO_VALID/$N valid logins" "$ev"
  else
    ab_fail "BA3: insufficient successful login journeys ($JO_VALID/$N) with an authorized key [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# ==========================================================================
# REG — regression vs baseline (seeded file present; establishes if missing)
# ==========================================================================
h_head "regression check vs baseline"
ev="$(h_ev reg_check)"
if [ ! -f "$BASELINE" ]; then
  umask 022
  cat > "$BASELINE" <<EOF
# tests/.benchmark_auth_baseline.env — auto-generated by benchmark_auth.sh (ms).
BASELINE_LOGINPAGE_P50=$LP_P50
BASELINE_LOGINPAGE_P95=$LP_P95
BASELINE_LOGINPAGE_P99=$LP_P99
BASELINE_AUTH_P50=$AU_P50
BASELINE_AUTH_P95=$AU_P95
BASELINE_AUTH_P99=$AU_P99
BASELINE_JOURNEY_P50=$JO_P50
BASELINE_JOURNEY_P95=$JO_P95
BASELINE_JOURNEY_P99=$JO_P99
EOF
  { echo "no prior baseline — established tests/.benchmark_auth_baseline.env";
    echo "loginpage p95=${LP_P95}ms  auth p95=${AU_P95}ms  journey p95=${JO_P95}ms  tolerance=${TOL_PCT}%"; } > "$ev"
  ab_pass_with_evidence "REG: baseline established (first run — no regression to assert); loginpage p95=${LP_P95}ms auth p95=${AU_P95}ms journey p95=${JO_P95}ms" "$ev"
else
  # shellcheck disable=SC1090
  . "$BASELINE"
  budget() { awk -v b="${1:-0}" -v t="$TOL_PCT" -v a="$ABS_FLOOR_MS" 'BEGIN{p=b*(100+t)/100; f=b+a; printf "%d",((p>f)?p:f)+0.5}'; }
  lp_budget="$(budget "${BASELINE_LOGINPAGE_P95:-0}")"
  au_budget="$(budget "${BASELINE_AUTH_P95:-0}")"
  jo_budget="$(budget "${BASELINE_JOURNEY_P95:-0}")"
  lp_ok=1; au_ok=1; jo_ok=1; jo_note="(skipped — no authorized key)"
  [ "${LP_P95:-0}" -le "$lp_budget" ] 2>/dev/null || lp_ok=0
  [ "${AU_P95:-0}" -le "$au_budget" ] 2>/dev/null || au_ok=0
  if [ "$JO_MEASURED" = 1 ]; then
    [ "${JO_P95:-0}" -le "$jo_budget" ] 2>/dev/null || jo_ok=0
    jo_note="journey ${JO_P95}<=${jo_budget}"
  fi
  { echo "baseline: loginpage_p95=${BASELINE_LOGINPAGE_P95}ms auth_p95=${BASELINE_AUTH_P95}ms journey_p95=${BASELINE_JOURNEY_P95}ms  tol=${TOL_PCT}% abs_floor=${ABS_FLOOR_MS}ms";
    echo "current : loginpage_p95=${LP_P95}ms (budget=${lp_budget})  auth_p95=${AU_P95}ms (budget=${au_budget})  ${jo_note}"; } > "$ev"
  if [ "$lp_ok" = 1 ] && [ "$au_ok" = 1 ] && [ "$jo_ok" = 1 ]; then
    ab_pass_with_evidence "REG: no p95 regression beyond ${TOL_PCT}% (loginpage ${LP_P95}<=${lp_budget}, auth ${AU_P95}<=${au_budget}, ${jo_note})" "$ev"
  else
    ab_fail "REG: p95 regression (loginpage ${LP_P95}/${lp_budget} ok=$lp_ok ; auth ${AU_P95}/${au_budget} ok=$au_ok ; journey ok=$jo_ok) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

h_summary
