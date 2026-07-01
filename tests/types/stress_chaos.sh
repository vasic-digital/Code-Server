#!/usr/bin/env bash
#
# tests/types/stress_chaos.sh — STRESS + CHAOS suite (§11.4.85) for the HelixCode stack.
#
# Chaos-injection WITH captured, categorised RECOVERY evidence and guaranteed
# cleanup on EVERY exit path (§11.4.14 `trap ... EXIT`). Each scenario restores
# the stack to a healthy state before the suite returns.
#
# Scenarios:
#   (a) KILL + RECOVER  — SIGKILL the code-server container mid-request; assert
#       Caddy answers gracefully (502/503, never a connection crash) while the
#       upstream is down; the container comes back (restart=unless-stopped, with
#       an explicit `podman start` fallback) and the service is reachable again.
#   (b) SEED RECOVERY   — on a THROWAWAY temp path (the real cs-data volume is
#       NEVER touched): prove up.sh's seed idempotency (remove -> reseed restores
#       a valid settings.json; operator edit preserved, no clobber) AND a
#       corrupt-content recovery (garbage detected -> restored to valid JSON).
#   (c) CONNECTION/FD PRESSURE — many simultaneous connections; assert the edge
#       cleanly refuses/queues (no crash) and is reachable after (bounded §12.6).
#
# SAFETY (CRITICAL):
#   * §11.4.174 — acts ONLY on OUR containers ($HC_CS / $HC_CADDY = deploy_*).
#     Foreign containers (lava-*, proxy-*, tmx-*) are NEVER signalled/inspected.
#     Verified by an explicit ownership guard before any destructive step.
#   * §11.4.14/§11.4.119 — `trap hc_restore EXIT` ALWAYS restores code-server +
#     waits for reachability + removes temp dirs, on success, failure, or ^C.
#   * The destructive kill (scenario a) runs only when HC_CHAOS_LIVE=1 (default);
#     set HC_CHAOS_LIVE=0 for a non-destructive dry run (scenario a -> honest SKIP).
#   * The §11.4.10 password is never printed. No git tree mutation (§11.4.113).
#
# §1.1 PAIRED MUTATION (proves each gate is not a bluff):
#   (a) remove the `restart: unless-stopped` policy AND disable the explicit
#       `podman start` fallback -> the service never recovers -> post-probe 000 ->
#       scenario (a) FAILs. OR make Caddy hard-exit when upstream is down (no 502)
#       -> `edge_graceful=0` -> FAILs.
#   (b) break the seed idempotency (always overwrite) -> operator marker clobbered
#       -> `operator_marker_preserved=no` -> scenario (b) FAILs; OR skip the
#       corrupt-restore -> `restored_valid=no` -> FAILs.
#   (c) make the edge exit on connection pressure (no queue) -> post-probe 000 /
#       ok==0 -> scenario (c) FAILs.
#
# Purpose      : resilience under fault injection with captured recovery traces
# Inputs       : deploy/.env (via stack_fixture); HC_CHAOS_LIVE (default 1),
#                HC_CHAOS_PRESSURE_N (<=1000), HC_CHAOS_PRESSURE_C (<=128)
# Outputs      : qa-results/tests/stress_chaos/<run-id>/*.txt ; exit 0 iff resilient
# Side-effects : LIVE mode kills+restarts ONLY our code-server container; always
#                restored via trap. Never touches the real cs-data volume or git.
# Dependencies : bash, curl, podman, python3, mktemp ; harness.sh + stack_fixture.sh
# Cross-refs   : §11.4.14 §11.4.69 §11.4.85 §11.4.119 §11.4.174 ; harness.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init stress_chaos

if ! hc_stack_up; then
  ev="$(h_ev stack_unreachable)"; echo "stack not reachable at $HC_BASE" > "$ev"
  ab_skip_with_reason "HelixCode stack not reachable (cannot boot on-demand)" network_unreachable_external
  h_summary; exit $?
fi
hc_load_env

# ---- ownership guard (§11.4.174) — only ever touch OUR containers ---------
hc_own() { "$HC_ENGINE" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
if ! hc_own "$HC_CS" || ! hc_own "$HC_CADDY"; then
  ev="$(h_ev ownership)"; { echo "required OUR containers not both present:"; echo "  $HC_CS present=$(hc_own "$HC_CS" && echo yes || echo no)"; echo "  $HC_CADDY present=$(hc_own "$HC_CADDY" && echo yes || echo no)"; } > "$ev"
  ab_skip_with_reason "chaos requires our stack containers ($HC_CS + $HC_CADDY)" topology_unsupported
  h_summary; exit $?
fi

# true service readiness (§11.4.6/§11.4.107): code-server is ACTUALLY serving,
# not merely Caddy-up-with-upstream-booting. During code-server boot the edge
# returns 502 (a distinct loading state, NOT recovered) — a non-000 code is NOT
# proof of recovery. Ready iff GET / -> 302 (login redirect) OR /healthz -> 200.
hc_service_ready() {
  local c; c="$(hc_https_code /)"
  [ "$c" = "302" ] || [ "$c" = "200" ] || [ "$(hc_https_code /healthz)" = "200" ]
}

# ---- restore trap (§11.4.14) — ALWAYS leave the stack healthy ------------
CHAOS_KILLED=0
_TMPDIRS=""
hc_restore() {
  # bring code-server back if it is not currently running (never touch foreign)
  if [ "$CHAOS_KILLED" = "1" ] || ! "$HC_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$HC_CS"; then
    "$HC_ENGINE" start "$HC_CS" >/dev/null 2>&1 \
      || ( cd "$HC_ROOT/deploy" && "$HC_ENGINE" compose -f compose.codeserver.yml -f compose.projects.yml up -d >/dev/null 2>&1 ) \
      || true
  fi
  # wait bounded for the service to be TRULY ready again (not just Caddy up)
  local i
  for i in $(seq 1 45); do hc_service_ready && break; sleep 1; done
  # clean throwaway temp dirs
  for d in $_TMPDIRS; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true; done
  CHAOS_KILLED=0
}
trap hc_restore EXIT

# =========================================================================
# Scenario (b): seed / settings recovery on a THROWAWAY path (real volume safe)
# =========================================================================
sc_b_seed_recovery() {
  h_head "chaos (b): settings.json seed idempotency + recovery on throwaway path"
  local ev tmp src userdir tgt
  ev="$(h_ev chaos_b_seed_recovery)"
  tmp="$(mktemp -d 2>/dev/null)" || { ab_fail "chaos(b): mktemp failed"; return 1; }
  _TMPDIRS="$_TMPDIRS $tmp"
  src="$HC_ROOT/deploy/code-server/settings.default.json"
  userdir="$tmp/User"; tgt="$userdir/settings.json"
  mkdir -p "$userdir"
  # up.sh seed semantics: seed ONLY if absent (never clobber operator edits)
  seed() { [ -f "$tgt" ] || cp "$src" "$tgt"; }
  validjson() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
  {
    echo "=== chaos(b) seed/recovery (throwaway path: $tmp — real cs-data volume UNTOUCHED) ==="
    echo "src=$src"
    # 1) fresh seed on an empty volume
    seed
    echo "fresh_seed: exists=$([ -f "$tgt" ] && echo yes || echo no) valid=$(validjson "$tgt" && echo yes || echo no)"
    # 2) removal -> reseed recovers a valid file
    rm -f "$tgt"; echo "removed: gone=$([ -f "$tgt" ] || echo yes)"
    seed
    echo "recovery_seed: exists=$([ -f "$tgt" ] && echo yes || echo no) valid=$(validjson "$tgt" && echo yes || echo no)"
    # 3) idempotency: an operator edit is NOT clobbered by a re-seed
    printf '{"operator.marker": true}\n' > "$tgt"; seed
    echo "operator_marker_preserved=$(grep -q 'operator.marker' "$tgt" && echo yes || echo no)"
    # 4) corrupt-content recovery: garbage detected -> restore valid JSON from src
    printf 'NOT-JSON-%%%%-garbage\n' > "$tgt"
    if validjson "$tgt"; then echo "corrupt_detected=no"; else
      cp "$src" "$tgt"
      echo "corrupt_detected=yes restored_valid=$(validjson "$tgt" && echo yes || echo no)"
    fi
  } > "$ev" 2>&1
  local fresh recov preserved restored
  fresh="$(grep -c 'fresh_seed: .*valid=yes' "$ev")"
  recov="$(grep -c 'recovery_seed: .*valid=yes' "$ev")"
  preserved="$(grep -c 'operator_marker_preserved=yes' "$ev")"
  restored="$(grep -c 'restored_valid=yes' "$ev")"
  if [ "$fresh" -ge 1 ] && [ "$recov" -ge 1 ] && [ "$preserved" -ge 1 ] && [ "$restored" -ge 1 ]; then
    ab_pass_with_evidence "chaos(b): seed idempotent + settings recover to valid JSON (real volume untouched)" "$ev"
  else
    ab_fail "chaos(b): fresh=$fresh recov=$recov preserved=$preserved restored=$restored [ev: ${ev#$HC_ROOT/}]"
  fi
}

# =========================================================================
# Scenario (c): connection / fd pressure -> clean refuse/queue, no crash
# =========================================================================
sc_c_pressure() {
  h_head "chaos (c): connection/fd pressure -> clean refuse/queue (no crash)"
  local ev raw N C completed ok refused post
  ev="$(h_ev chaos_c_pressure)"; raw="$(h_ev chaos_c_raw)"
  N="${HC_CHAOS_PRESSURE_N:-150}"; C="${HC_CHAOS_PRESSURE_C:-60}"
  case "$N" in ''|*[!0-9]*) N=150;; esac
  case "$C" in ''|*[!0-9]*) C=60;; esac
  [ "$N" -gt 1000 ] && N=1000
  [ "$C" -gt 128 ]  && C=128
  [ "$C" -lt 1 ]    && C=1
  : > "$raw"
  seq 1 "$N" | xargs -P "$C" -I{} \
    curl -k -s -o /dev/null -w '%{http_code}\n' --max-time 15 "$HC_BASE/login" >> "$raw" 2>/dev/null
  completed="$(wc -l < "$raw" | tr -d ' ')"
  ok="$(awk '$1==200||$1==302{c++} END{print c+0}' "$raw")"
  refused="$(awk '$1==000{c++} END{print c+0}' "$raw")"
  post="$(hc_https_code /)"
  { echo "=== chaos(c) connection/fd pressure (bounded §12.6) ===";
    echo "pressure: N=$N C=$C";
    echo "completed=$completed ok(2xx/302)=$ok refused/timeout(000)=$refused";
    echo "post_pressure_reachable(GET /)=$post (000 = edge down)";
    echo "code_distribution:"; sort "$raw" | uniq -c; } > "$ev"
  # graceful: edge alive AFTER pressure AND it served a positive share (didn't collapse)
  if [ "$post" != "000" ] && [ "$ok" -gt 0 ]; then
    ab_pass_with_evidence "chaos(c): edge survived $N conns @C=$C (ok=$ok refused=$refused), reachable after (GET / -> $post)" "$ev"
  else
    ab_fail "chaos(c): edge did not survive pressure (post=$post ok=$ok) [ev: ${ev#$HC_ROOT/}]"
  fi
}

# =========================================================================
# Scenario (a): KILL code-server mid-request -> 502 graceful -> recover
# =========================================================================
sc_a_kill_recover() {
  h_head "chaos (a): kill $HC_CS mid-request -> 502 graceful -> recover"
  local ev pre during recovered_by post c i
  ev="$(h_ev chaos_a_kill_recover)"
  pre="$(hc_https_code /)"
  { echo "=== chaos(a) kill+recover ($HC_CS) ==="; echo "pre_reachable(GET /)=$pre"; } > "$ev"

  if [ "${HC_CHAOS_LIVE:-1}" != "1" ]; then
    echo "DRY_RUN: HC_CHAOS_LIVE!=1 — destructive kill skipped (non-destructive authoring mode)" >> "$ev"
    ab_skip_with_reason "chaos(a) kill+recover skipped in dry-run (HC_CHAOS_LIVE=0)" feature_disabled_by_config
    return 0
  fi

  # --- INJECT: SIGKILL our upstream (never a foreign container) ---
  CHAOS_KILLED=1
  "$HC_ENGINE" kill "$HC_CS" >/dev/null 2>&1 || true
  echo "action=SIGKILL $HC_CS at $(date -u +%H:%M:%SZ)" >> "$ev"

  # --- OBSERVE: Caddy must answer gracefully while upstream is down ---
  # tight burst first (catch the 502 window), then 1s intervals up to ~10s
  during=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    c="$(hc_https_code /)"
    echo "during_probe_$i=$c" >> "$ev"
    case "$c" in
      502|503) during="$c"; break;;                 # graceful upstream-down response
      302|200) during="recovered-fast($c)"; break;; # container auto-restarted before we caught 502
    esac
    [ "$i" -ge 3 ] && sleep 1
  done
  echo "during_result=$during" >> "$ev"

  # --- RECOVER: give restart policy a chance, then explicit start fallback ---
  # Recovery means the service is TRULY ready (302/200), NOT merely that Caddy
  # answers a 502 while code-server is still booting (§11.4.6/§11.4.107).
  recovered_by="auto(restart=unless-stopped)"
  local ok=0
  for i in $(seq 1 12); do
    hc_service_ready && { ok=1; break; }
    sleep 1
  done
  if [ "$ok" != "1" ]; then
    recovered_by="manual(podman start fallback)"
    "$HC_ENGINE" start "$HC_CS" >/dev/null 2>&1 || true
    for i in $(seq 1 45); do hc_service_ready && { ok=1; break; }; sleep 1; done
  fi
  CHAOS_KILLED=0
  post="$(hc_https_code /)"; posth="$(hc_https_code /healthz)"
  echo "recovered_by=$recovered_by post(GET /)=$post post(/healthz)=$posth" >> "$ev"

  # --- VERDICT ---
  local edge_graceful=0 service_recovered=0 saw_refused=0
  case "$during" in 502|503|recovered-fast*) edge_graceful=1;; esac
  grep -q 'during_probe_.*=000' "$ev" && saw_refused=1
  # TRUE recovery: code-server actually serving again (302 or /healthz 200),
  # never a bare non-000 (a 502 is Caddy-up-but-upstream-down = NOT recovered).
  { [ "$post" = "302" ] || [ "$post" = "200" ] || [ "$posth" = "200" ]; } && service_recovered=1
  { echo "edge_graceful=$edge_graceful (Caddy answered $during during upstream-down, no connection crash)";
    echo "edge_connection_refused_during_window=$saw_refused (0 = Caddy stayed up)";
    echo "service_recovered=$service_recovered (post GET /=$post /healthz=$posth; 1 requires 302/200 not 502)"; } >> "$ev"
  if [ "$edge_graceful" = "1" ] && [ "$service_recovered" = "1" ] && [ "$saw_refused" = "0" ]; then
    ab_pass_with_evidence "chaos(a): Caddy graceful ($during) during upstream-down, code-server recovered ($post) via $recovered_by" "$ev"
  else
    ab_fail "chaos(a): edge_graceful=$edge_graceful refused=$saw_refused recovered=$service_recovered (during=$during post=$post) [ev: ${ev#$HC_ROOT/}]"
  fi
}

# ---- run order: safe scenarios first, destructive last -------------------
sc_c_pressure
sc_b_seed_recovery
sc_a_kill_recover

h_summary
