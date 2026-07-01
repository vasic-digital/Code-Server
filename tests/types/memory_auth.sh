#!/usr/bin/env bash
# tests/types/memory_auth.sh — helix-auth GATE memory soak (§11.4.169 memory ; §12.6).
#
# Purpose:      The 2026-07-01 auth pivot introduced a host-native forward-auth
#               gate `helix-auth` (systemd --user, loopback 127.0.0.1:8081) that
#               Caddy calls on EVERY request (GET /auth) and that mints sessions on
#               POST /login. A leak here would grow unbounded under normal traffic
#               and eventually breach §12.6. This suite samples the GATE process's
#               resident memory over a bounded window under light login-shaped load
#               and proves, with REAL captured time-series evidence:
#                 (MA1) gate RSS stays BOUNDED — no monotonic unbounded growth
#                       (max <= min * GROWTH_FACTOR AND max < CEIL_MB).
#                 (MA2) the gate's PEAK RSS stays under §12.6's 60% of TOTAL host
#                       memory (OUR procedure's budget, not other workloads' —
#                       §11.4.174); total host used% recorded as context only.
#               The gate is host-native (NOT a container), so RSS is read from the
#               PID that actually OWNS the loopback gate port (§11.4.174: positive
#               ownership by the served endpoint, never a loose pgrep name match).
#               The observer is light: read-only `ps -o rss` + a few cheap read-only
#               GETs per interval (§11.4.119 read-only, §12.6-friendly).
# Usage:        bash tests/types/memory_auth.sh
#               HC_MEM_SAMPLES=12 HC_MEM_INTERVAL=5 bash tests/types/memory_auth.sh
# Inputs:       deploy/.env + HELIX_AUTH_ADDR via the fixture ; HC_MEM_SAMPLES /
#               HC_MEM_INTERVAL ; HC_GATE_CEIL_MB / HC_GATE_GROWTH (tenths)
# Outputs:      per-run evidence under qa-results/tests/memory_auth/<run-id>/
# Side-effects: read-only ps + read-only HTTP; never mutates the shared stack, never
#               signals/kills any process (§11.4.174), never touches the git tree.
# Dependencies: bash, ps, awk, free ; ss OR lsof (to resolve the gate PID by port) ;
#               curl (light load)
# Cross-references: §11.4.169 §11.4.24 §11.4.119 §11.4.174 §12.6 §11.4.6 ;
#                   harness.sh stack_fixture.sh ; spec 2026-07-01-auth-pivot-ssh-key.md
#
# §1.1 PAIRED MUTATION (per case, for the meta-test sweep):
#   MA1  set HC_GATE_GROWTH below 10 (e.g. 5 => 0.5x) OR seed a fake doubling
#        series -> max > min*factor -> the "gate RSS bounded" assert FAILs.
#   MA2  set HC_GATE_CEIL_PCT=0 -> the gate's (>=0) usage pct is never < 0 -> the
#        "gate under §12.6 budget" assert FAILs.
#
# ANTI-BLUFF (§11.4/§11.4.69): every PASS cites a non-empty time-series file. When
# the auth-pivot stack is not deployed OR the gate PID cannot be resolved, the suite
# SKIPs-with-reason(topology_unsupported) — never a fake PASS. Real green happens at
# the conductor's live-validation step against the deployed gate (§11.4.40).
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init memory_auth

SAMPLES="${HC_MEM_SAMPLES:-12}"
INTERVAL="${HC_MEM_INTERVAL:-5}"
GROWTH_FACTOR="${HC_GATE_GROWTH:-20}"   # tenths: 20 => max must be <= min * 2.0 (Go GC headroom, still catches a leak)
CEIL_MB="${HC_GATE_CEIL_MB:-512}"       # absolute RSS ceiling for the gate (Go gate baseline is tens of MB)
HOST_CEIL="${HC_GATE_CEIL_PCT:-60}"     # §12.6 host-memory budget ceiling (percent)

# ---- runtime guards ------------------------------------------------------
if ! h_require ps || ! h_require awk || ! h_require free; then
  ab_skip_with_reason "memory_auth (ps/awk/free absent)" topology_unsupported
  h_summary; exit $?
fi
if ! h_require ss && ! h_require lsof; then
  ab_skip_with_reason "memory_auth (neither ss nor lsof present to resolve the gate PID by port)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_new_stack_up; then
  ev="$(h_ev stack_down)"
  { echo "auth-pivot ssh-key stack not deployed (conductor deploys it live later)";
    echo "probe: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "memory_auth: ssh-key auth gate not deployed ($HC_NEW_STACK_DETAIL)" topology_unsupported
  h_summary; exit $?
fi

# ---- resolve the PID that OWNS the gate loopback port (§11.4.174) ----------
# Strongest ownership discriminator: the process actually serving OUR gate port,
# never a loose `pgrep helix-auth` name match that could hit an unrelated process.
hc_listener_pid() {
  local addr="$1" port pid
  port="${addr##*:}"
  pid="$(ss -ltnpH 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {print}' \
          | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)"
  [ -n "$pid" ] && { printf '%s' "$pid"; return 0; }
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n1)"
    [ -n "$pid" ] && { printf '%s' "$pid"; return 0; }
  fi
  return 1
}

# rss of <pid> in MiB (ps -o rss= is KiB). 0 if the pid is gone/unreadable.
rss_mib() {
  local pid="$1" kib
  [ -n "$pid" ] || { echo 0; return; }
  kib="$(ps -o rss= -p "$pid" 2>/dev/null | tr -dc '0-9')"
  awk -v k="${kib:-0}" 'BEGIN{printf "%d",(k/1024)+0.5}'
}

GATE_PID="$(hc_listener_pid "$HC_GATE_ADDR" || true)"
if [ -z "$GATE_PID" ]; then
  ev="$(h_ev gate_pid_absent)"
  { echo "gate reachable (${HC_GATE_ADDR}) but no host-native PID owns the port here";
    echo "(gate may be containerized, or ss/lsof cannot see the owner in this env)";
    echo "detail: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "memory_auth: could not resolve a host-native gate PID owning ${HC_GATE_ADDR}" topology_unsupported
  h_summary; exit $?
fi
h_log "gate PID owning ${HC_GATE_ADDR} = $GATE_PID (ownership-verified by served port, §11.4.174)"

GATE_SERIES="$(h_ev ma_series_gate)"; HOST_SERIES="$(h_ev ma_series_host)"
: > "$GATE_SERIES"; : > "$HOST_SERIES"
{ echo "gate memory soak: $SAMPLES samples @ ${INTERVAL}s under light gate load";
  echo "initial gate PID=$GATE_PID (${HC_GATE_ADDR}) ; ceil=${CEIL_MB}MiB growth=min*${GROWTH_FACTOR}/10"; } >> "$GATE_SERIES"

h_head "gate RSS soak: $SAMPLES samples @ ${INTERVAL}s"
g_min=""; g_max=""; g_ok=0; host_max=0; n=0
while [ "$n" -lt "$SAMPLES" ]; do
  n=$((n+1))
  # light gate-shaped load (read-only): forward-auth hot path + a fresh challenge
  # issuance + the TLS edge login page. Keeps the gate active; allocates a nonce.
  hc_http_code "http://${HC_GATE_ADDR}/auth"    >/dev/null 2>&1
  hc_http_code "http://${HC_GATE_ADDR}/login"   >/dev/null 2>&1
  hc_http_code "http://${HC_GATE_ADDR}/healthz" >/dev/null 2>&1
  hc_https_code /login                          >/dev/null 2>&1

  # re-resolve the PID each sample: if the gate restarted mid-soak the owner
  # changes; fold only POSITIVE RSS so a transient gone-pid never collapses min.
  cur_pid="$(hc_listener_pid "$HC_GATE_ADDR" || echo "$GATE_PID")"
  g_mib="$(rss_mib "$cur_pid")"
  host_pct="$(free -b | awk '/^Mem:/{printf "%d",(($3/$2)*100)+0.5}')"

  printf 'sample=%s pid=%s rss_mib=%s\n' "$n" "${cur_pid:-?}" "$g_mib" >> "$GATE_SERIES"
  printf 'sample=%s host_used_pct=%s\n' "$n" "$host_pct" >> "$HOST_SERIES"

  if [ "${g_mib:-0}" -gt 0 ]; then
    g_ok=$((g_ok+1))
    [ -z "$g_min" ] && { g_min="$g_mib"; g_max="$g_mib"; }
    [ "$g_mib" -lt "$g_min" ] && g_min="$g_mib"; [ "$g_mib" -gt "$g_max" ] && g_max="$g_mib"
  fi
  [ "${host_pct:-0}" -gt "$host_max" ] && host_max="$host_pct"

  h_log "sample $n/$SAMPLES: gate=${g_mib}MiB (pid=$cur_pid) host=${host_pct}%"
  [ "$n" -lt "$SAMPLES" ] && sleep "$INTERVAL"
done

# bounded: max <= min * (GROWTH_FACTOR/10) AND max < CEIL_MB
bounded() { awk -v mn="$1" -v mx="$2" -v g="$GROWTH_FACTOR" -v ceil="$CEIL_MB" \
  'BEGIN{ lim=mn*(g/10.0); exit !((mx <= lim) && (mx < ceil)); }'; }

# ---- MA1 gate RSS bounded -------------------------------------------------
{ echo "--- summary ---";
  echo "gate MiB: min=$g_min max=$g_max limit=min*${GROWTH_FACTOR}/10 ceil=$CEIL_MB valid_samples=$g_ok/$SAMPLES"; } >> "$GATE_SERIES"
if [ -n "$g_min" ] && [ "$g_ok" -ge "$((SAMPLES/2))" ] && bounded "$g_min" "$g_max"; then
  ab_pass_with_evidence "MA1: helix-auth gate RSS bounded over $SAMPLES samples (min=${g_min}MiB max=${g_max}MiB, no unbounded growth, <${CEIL_MB}MiB)" "$GATE_SERIES"
else
  ab_fail "MA1: gate RSS unbounded/over-ceiling (min=${g_min:-?} max=${g_max:-?} ceil=$CEIL_MB valid=$g_ok/$SAMPLES) [ev: ${GATE_SERIES#$HC_ROOT/}]"
fi

# ---- MA2 gate under §12.6 60% of TOTAL host (not other workloads) ----------
host_total_mib="$(free -m | awk '/^Mem:/{print $2}')"
gate_pct="$(awk -v p="${g_max:-0}" -v t="${host_total_mib:-1}" 'BEGIN{ if(t<=0)t=1; printf "%d",((p/t)*100)+0.5 }')"
{ echo "--- summary ---";
  echo "gate peak RSS = ${g_max:-0}MiB of ${host_total_mib}MiB total host";
  echo "gate usage = ${gate_pct}% of total host memory ; §12.6 ceiling = ${HOST_CEIL}%";
  echo "context: total host used (ALL workloads incl. others, §11.4.174) peaked at ${host_max}%"; } >> "$HOST_SERIES"
if [ "${gate_pct:-100}" -lt "$HOST_CEIL" ]; then
  ab_pass_with_evidence "MA2: helix-auth gate used ${gate_pct}% of host memory (< §12.6 ${HOST_CEIL}% budget; peak ${g_max:-0}MiB)" "$HOST_SERIES"
else
  ab_fail "MA2: gate used ${gate_pct}% of host memory (>= §12.6 ${HOST_CEIL}% budget; peak ${g_max:-0}MiB) [ev: ${HOST_SERIES#$HC_ROOT/}]"
fi

h_summary
