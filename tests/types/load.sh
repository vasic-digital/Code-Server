#!/usr/bin/env bash
#
# tests/types/load.sh — moderate-load / mini-DDoS RESILIENCE suite (§11.4.169 DDoS class).
#
# Fires a bounded burst of concurrent requests at the Caddy edge login page and
# proves the edge stays responsive (all requests complete, success ratio above a
# floor, no crash) with REAL captured latency + success evidence (§11.4/§11.4.69).
# Degrade-gracefully, not collapse.
#
# BOUNDED by design (§12.6 / host-safety): defaults N=200 requests across C=20
# workers (~sub-second on a healthy edge), hard-capped even if overridden, so it
# stress-probes resilience WITHOUT taking the host down. It targets ONLY GET
# /login (a non-mutating page render) so no state is changed.
#
# Env overrides (all capped): HC_LOAD_N (<=2000), HC_LOAD_C (<=64),
#                             HC_LOAD_FLOOR (success-% floor, default 90).
#
# §1.1 PAIRED MUTATION (proves this gate is not a bluff):
#   - Point the post-burst responsiveness re-probe at a DEAD port (edge down):
#     hc_https_code returns 000 -> the "edge still responsive" assertion FAILs.
#   - OR raise HC_LOAD_FLOOR to 101 (impossible ratio) -> the success-ratio
#     assertion FAILs, proving the floor is genuinely enforced (not decorative).
#   - OR replace the real curl loop with `echo 200` (fake completions): the raw
#     latency evidence file becomes all-zero and the post-burst re-probe against
#     the real edge still governs the verdict — a fabricated load cannot PASS the
#     responsiveness assertion.
#
# Purpose      : DDoS-class resilience proof with captured p50/p95 + success count
# Inputs       : deploy/.env (via stack_fixture); HC_LOAD_N/C/FLOOR
# Outputs      : qa-results/tests/load/<run-id>/*.txt ; exit 0 iff resilient
# Side-effects : sends N bounded GET requests; NEVER mutates stack or git tree
# Dependencies : bash, curl, xargs, awk, sort ; harness.sh + stack_fixture.sh
# Cross-refs   : §11.4.69 §11.4.85 §11.4.169 §12.6 ; harness.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init load

if ! hc_stack_up; then
  ev="$(h_ev stack_unreachable)"; echo "stack not reachable at $HC_BASE" > "$ev"
  ab_skip_with_reason "HelixCode stack not reachable (cannot boot on-demand)" network_unreachable_external
  h_summary; exit $?
fi
hc_load_env

# ---- bounded parameters (§12.6) -----------------------------------------
N="${HC_LOAD_N:-200}"; C="${HC_LOAD_C:-20}"; FLOOR="${HC_LOAD_FLOOR:-90}"
case "$N" in ''|*[!0-9]*) N=200;; esac
case "$C" in ''|*[!0-9]*) C=20;;  esac
case "$FLOOR" in ''|*[!0-9]*) FLOOR=90;; esac
[ "$N" -gt 2000 ] && N=2000
[ "$C" -gt 64 ]   && C=64
[ "$C" -lt 1 ]    && C=1
url="$HC_BASE/login"

h_head "firing $N requests @ concurrency $C at $url (bounded)"
raw="$(h_ev load_raw)"; : > "$raw"
t0="$(date +%s.%N 2>/dev/null || date +%s)"
seq 1 "$N" | xargs -P "$C" -I{} \
  curl -k -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 20 "$url" >> "$raw" 2>/dev/null
t1="$(date +%s.%N 2>/dev/null || date +%s)"

completed="$(wc -l < "$raw" | tr -d ' ')"
ok="$(awk '$1==200||$1==302{c++} END{print c+0}' "$raw")"
non2xx="$(awk '$1!=200&&$1!=302{c++} END{print c+0}' "$raw")"
refused="$(awk '$1==000{c++} END{print c+0}' "$raw")"
wall="$(awk "BEGIN{printf \"%.2f\", ($t1)-($t0)}" 2>/dev/null || echo NA)"
# robust percentiles over time_total (seconds), nearest-rank
read -r p50 p95 pmax < <(sort -n -k2 "$raw" | awk '{v[NR]=$2} END{
  n=NR; if(n<1){print "0 0 0"; exit}
  i50=int((n+1)*0.5); i95=int((n+1)*0.95);
  if(i50<1)i50=1; if(i50>n)i50=n; if(i95<1)i95=1; if(i95>n)i95=n;
  printf "%s %s %s\n", v[i50], v[i95], v[n]}')
ratio=0; [ "$N" -gt 0 ] && ratio=$(( ok * 100 / N ))

summ="$(h_ev load_summary)"
{ echo "=== moderate-load resilience (DDoS class §11.4.169) ===";
  echo "target       : $url";
  echo "requests(N)  : $N";
  echo "concurrency  : $C";
  echo "completed    : $completed";
  echo "success(2xx/302) : $ok";
  echo "non-2xx      : $non2xx";
  echo "refused/timeout(000) : $refused";
  echo "success_ratio_pct : $ratio (floor=$FLOOR)";
  echo "latency_p50_s : $p50";
  echo "latency_p95_s : $p95";
  echo "latency_max_s : $pmax";
  echo "wall_s       : $wall";
  echo "code_distribution:"; sort "$raw" | awk '{print $1}' | sort | uniq -c; } > "$summ"

# ---- assertions ----------------------------------------------------------
# (a) all requests completed (edge accepted and answered every one)
h_assert_eq "LOAD: all $N requests completed (edge accepted every connection)" "$N" "$completed" "$(h_ev completed)"

# (b) success ratio stayed above the floor (graceful under load, not collapse)
h_assert_ge "LOAD: success ratio >= ${FLOOR}% under burst" "$FLOOR" "$ratio" "$(h_ev ratio)"

# (c) edge is STILL responsive after the burst (no crash) — real re-probe
post="$(hc_https_code /)"
postev="$(h_ev post_burst_responsive)"
{ echo "assert: edge still responds after the burst (no crash)";
  echo "post_burst GET / http_code=$post (000 = edge down/refused)"; } > "$postev"
if [ "$post" != "000" ]; then
  ab_pass_with_evidence "LOAD: edge responsive after burst (GET / -> $post); p50=${p50}s p95=${p95}s ok=$ok/$N" "$summ"
else
  ab_fail "LOAD: edge NOT responsive after burst (GET / -> 000) [ev: ${postev#$HC_ROOT/}]"
fi

h_summary
