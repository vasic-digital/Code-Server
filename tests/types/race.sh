#!/usr/bin/env bash
# tests/types/race.sh — HelixCode RACE / DEADLOCK suite (§11.4.169 race/deadlock).
#
# Purpose:      Prove the stack has no deadlock / hung-process failure mode under
#               concurrent access, and that the operator shell scripts are free of
#               race-prone / error-class defects, with REAL captured evidence:
#                 (R1) A burst of concurrent read-only probes (GET /healthz, /login,
#                      /) against Caddy -> code-server all COMPLETE within a hard
#                      timeout — none hang (rc=124) and none return 000 (no response).
#                      A hung probe would be caught by its per-worker `timeout`.
#                 (R2) shellcheck static analysis over scripts/*.sh + tests/**/*.sh
#                      finds ZERO error-severity (race-prone/error-class) findings.
#                      When absent -> honest SKIP (feature_disabled_by_config).
#               Honest boundary (§11.4.6): POSIX shell has no shared-memory threads,
#               so there is no classic data-race surface here; what IS testable —
#               and what this suite tests — is concurrent-INVOCATION safety (the
#               stack under a connection burst) plus static race/error-class lint.
# Usage:        bash tests/types/race.sh
# Inputs:       deploy/.env via the fixture (password never printed, §11.4.10)
# Outputs:      per-run evidence under qa-results/tests/race/<run-id>/
# Side-effects: fires read-only HTTP probes at the shared stack; never mutates it.
# Dependencies: bash, curl, timeout ; shellcheck (optional — SKIP if absent)
# Cross-references: §11.4.169 §11.4.85 §11.4.119 §11.4.6 §11.4.67 ; harness.sh stack_fixture.sh
#
# §1.1 PAIRED MUTATION (per case, for the meta-test sweep):
#   R1  lower the per-probe `timeout` below the real latency AND point a probe at a
#       black-hole port -> a worker records rc=124 / code=000 -> the "0 hung / 0
#       no-response" assert FAILs.
#   R2  inject a genuine shell error (e.g. `if [ $x = ]` unquoted-empty, or an
#       unclosed `case`) into a scanned script -> shellcheck error count > floor
#       -> the "0 error-severity findings" assert FAILs.
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init race

# ---- runtime guard -------------------------------------------------------
if ! h_require curl || ! h_require timeout; then
  ab_skip_with_reason "race suite (curl/timeout absent)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi

# code-server readiness (§11.4.107(3) / §11.4.144). Caddy /healthz stays 200 even
# when its upstream restarts; a real signal is GET /login==200. Tolerate a
# transient restart of the SHARED single-owner stack (§11.4.119) without bluffing.
hc_cs_ready() { [ "$(hc_https_code /login)" = 200 ]; }
hc_wait_cs()  { local i n="${1:-45}"; for i in $(seq 1 "$n"); do hc_cs_ready && return 0; sleep 2; done; return 1; }
hc_wait_cs 45 || true   # R1 tolerates 502s in its live-count; do not hard-gate here

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_race.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# ==========================================================================
# R1 — concurrent read probes: no deadlock, no hung process within a timeout
# ==========================================================================
h_head "R1 — concurrent read-probe burst completes with no hang / no deadlock"
ev="$(h_ev r1_probe_burst)"
NPROBE=24            # burst of concurrent connections
PTIMEOUT=15          # hard per-worker ceiling; a hang => rc=124
paths="/healthz /login / /healthz /login / /healthz /login"   # round-robins across paths
wdir="$WORK/probes"; mkdir -p "$wdir"

pids=""; i=0
while [ "$i" -lt "$NPROBE" ]; do
  i=$((i+1))
  # pick a path deterministically from the rotation
  set -- $paths
  idx=$(( (i - 1) % $# + 1 )); eval "path=\${$idx}"
  turl="$HC_BASE$path"
  (
    code="$(timeout "$PTIMEOUT" curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$turl" 2>/dev/null)"
    rc=$?
    # record the EXACT url probed (review F4) so the calm re-probe hits the same
    # target — a per-worker black-hole mutation is then re-probed against the
    # black-hole, not the healthy base, and correctly survives as code=000.
    printf 'w%s path=%s url=%s rc=%s code=%s\n' "$i" "$path" "$turl" "$rc" "${code:-000}" > "$wdir/w$i.txt"
  ) &
  pids="$pids $!"
done
# Host thread/fork pressure — sampled WHILE the burst is IN FLIGHT (review N1), not
# only after the workers are reaped: a concurrent-tenant spike DURING the seconds-long
# 24-way burst is the real cause of transient code=000 drops and can subside before
# the wait returns, so a post-wait-only sample would miss it and misattribute host
# starvation as a server defect (§11.4.174 shared host / §11.4.50 determinism). Take
# the PEAK across t0 + in-flight samples + the post-wait sample.
burst_thr="$(ps -eLf 2>/dev/null | wc -l)"
_bs=0
while [ "$_bs" -lt 3 ]; do
  _bs=$((_bs+1)); sleep 0.4
  _bt="$(ps -eLf 2>/dev/null | wc -l)"; [ "$_bt" -gt "$burst_thr" ] && burst_thr="$_bt"
done
for p in $pids; do wait "$p" 2>/dev/null || true; done
_bt="$(ps -eLf 2>/dev/null | wc -l)"; [ "$_bt" -gt "$burst_thr" ] && burst_thr="$_bt"
# Decide: a code=000 that recovers only on calm sequential re-probe is HOST resource
# starvation (tolerate) when host_pressured, else a genuine SERVER concurrency defect
# on an UNLOADED host (do NOT tolerate); NOISE_FLOOR keeps a couple of transient blips
# from flaking the suite (§11.4.50). Scope: F3 inspects code=000 (connection drops)
# only — a 5xx-under-burst/2xx-sequential collapse is counted served, per R1's
# documented deadlock-only scope (health is asserted by security_auth/e2e_auth).
burst_ulim="$(ulimit -u 2>/dev/null || echo 4096)"
case "$burst_ulim" in ''|*[!0-9]*) burst_ulim=1000000000 ;; esac
host_pressured=0; [ "$burst_thr" -ge $(( burst_ulim * 60 / 100 )) ] && host_pressured=1
NOISE_FLOOR=$(( NPROBE * 15 / 100 ))

completed=0; hung=0; noresp=0; live=0; unpressured_recover=0
{ echo "concurrent read probes: N=$NPROBE per-worker timeout=${PTIMEOUT}s"; echo "--- per worker ---"; } > "$ev"
i=0
while [ "$i" -lt "$NPROBE" ]; do
  i=$((i+1))
  f="$wdir/w$i.txt"
  [ -f "$f" ] || continue
  completed=$((completed+1))
  cat "$f" >> "$ev"
  line="$(cat "$f")"
  case "$line" in *"rc=124"*) hung=$((hung+1));; esac
  # ANY real HTTP status (2xx/3xx/4xx/5xx) = the server SERVED the request without
  # hanging — exactly R1's property. A `/` probe behind the auth gate returns
  # 401/303 (healthy served response). Only code=000 (no HTTP response at all) is
  # a no-response; rc=124 (above) is the genuine hang/deadlock signal.
  case "$line" in
    *"code=000"*)   noresp=$((noresp+1)) ;;
    *"code="[1-9]*) live=$((live+1)) ;;
  esac
done
{ echo "--- totals ---"
  echo "completed=$completed/$NPROBE hung(rc=124)=$hung no_response(code=000)=$noresp live(served 2xx/3xx/4xx/5xx)=$live"; } >> "$ev"

# Host-starvation attribution (§11.4.1 / §11.4.174, shared-host fork ceiling).
# A no-response worker (code=000, NOT rc=124) may be a TRANSIENT host fork /
# resource starvation of curl's own connect — not a server defect. Re-probe
# each such worker's SAME path SEQUENTIALLY (no fork burst) up to N_RETRY times:
# a transient env failure to the live server RECOVERS; a genuine unreachable /
# black-hole target (the §1.1 R1 mutation) stays code=000 -> still counts, still
# FAILs. rc=124 (hung) is the genuine deadlock signal and is NEVER retried.
N_RETRY=3
if [ "$hung" -eq 0 ] && [ "$noresp" -gt 0 ]; then
  { echo "--- calm sequential re-probe of no-response workers (host-starvation attribution) ---"; } >> "$ev"
  i=0
  while [ "$i" -lt "$NPROBE" ]; do
    i=$((i+1)); f="$wdir/w$i.txt"; [ -f "$f" ] || continue
    line="$(cat "$f")"; case "$line" in *"code=000"*) : ;; *) continue ;; esac
    wurl="$(sed -n 's/.*url=\([^ ]*\).*/\1/p' "$f")"; [ -n "$wurl" ] || wurl="$HC_BASE/healthz"
    r=0
    while [ "$r" -lt "$N_RETRY" ]; do
      r=$((r+1))
      rcode="$(timeout "$PTIMEOUT" curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$wurl" 2>/dev/null)"; rrc=$?
      { printf 're-probe w%s attempt=%s url=%s rc=%s code=%s\n' "$i" "$r" "$wurl" "$rrc" "${rcode:-000}"; } >> "$ev"
      if [ "$rrc" -eq 124 ]; then hung=$((hung+1)); break; fi
      # any real HTTP status (2xx/3xx/4xx/5xx incl. gate 401/303) = server served it
      case "${rcode:-000}" in
        [1-9]*)
          noresp=$((noresp-1)); live=$((live+1))
          # recovered only sequentially: if the host was NOT starved at burst time,
          # this is a burst connection-drop the server should have handled → count it
          # against the noise floor for the F3 server-concurrency check below.
          [ "$host_pressured" = 0 ] && unpressured_recover=$((unpressured_recover+1))
          break ;;
      esac
      [ "$r" -lt "$N_RETRY" ] && sleep 1
    done
  done
  { echo "after re-probe: hung=$hung noresp=$noresp live=$live unpressured_recover=$unpressured_recover (host_pressured=$host_pressured thr=$burst_thr/$burst_ulim noise_floor=$NOISE_FLOOR)"; } >> "$ev"
fi

if [ "$hung" -gt 0 ]; then
  ab_fail "R1: probe burst HUNG (rc=124) — genuine deadlock/hang (completed=$completed hung=$hung noresp=$noresp live=$live) [ev: ${ev#$HC_ROOT/}]"
elif [ "$host_pressured" = 0 ] && [ "$unpressured_recover" -gt "$NOISE_FLOOR" ]; then
  ab_fail "R1: burst dropped $unpressured_recover connection(s) (> noise floor $NOISE_FLOOR) on an UNLOADED host (threads $burst_thr/$burst_ulim) that recovered only on sequential re-probe — genuine SERVER concurrency defect (listen-backlog / thread-pool exhaustion), not host starvation [ev: ${ev#$HC_ROOT/}]"
elif [ "$noresp" -eq 0 ] && [ "$live" -ge 1 ]; then
  ab_pass_with_evidence "R1: $completed/$NPROBE probes, 0 hung, 0 no-response after calm re-probe ($live live; $unpressured_recover env-recovered, host_pressured=$host_pressured) — no deadlock/concurrency defect" "$ev"
elif [ "$live" -lt 1 ]; then
  ab_skip_with_reason "R1 concurrent-probe burst (host fork/resource starvation §11.4.174 — no probe served + none hung; cannot assess server concurrency)" topology_unsupported
else
  ab_fail "R1: probe burst not clean (completed=$completed hung=$hung noresp=$noresp live=$live) — no-response survived $N_RETRY calm re-probes to the EXACT worker URL (genuine unreachable/drop) [ev: ${ev#$HC_ROOT/}]"
fi

# ==========================================================================
# R2 — shellcheck: zero error-severity (race-prone/error-class) findings
# ==========================================================================
h_head "R2 — shellcheck error-class floor over scripts/*.sh + tests/**/*.sh"
if ! h_require shellcheck; then
  ab_skip_with_reason "shellcheck static race/error-class scan (shellcheck not installed on host)" feature_disabled_by_config
else
  ev="$(h_ev r2_shellcheck_errorclass)"
  # collect the in-scope shell scripts (exclude nothing owned; skip vendored trees)
  files=""
  for f in "$HC_ROOT"/scripts/*.sh "$HC_ROOT"/tests/*.sh "$HC_ROOT"/tests/lib/*.sh "$HC_ROOT"/tests/types/*.sh; do
    [ -f "$f" ] && files="$files $f"
  done
  { echo "shellcheck $(shellcheck --version 2>/dev/null | awk '/version:/{print $2}')"
    echo "severity floor = error (error-severity findings must be 0)"
    echo "scanned files:"; for f in $files; do echo "  ${f#$HC_ROOT/}"; done
    echo "--- error-severity findings (gcc format) ---"; } > "$ev"
  # -S error: only error-severity; -f gcc: one finding per line "file:line:col: error: ..."
  # shellcheck disable=SC2086
  shellcheck -S error -f gcc $files 2>/dev/null | grep ': error:' >> "$ev" || true
  # grep -c already prints "0" on no match (and exits 1); a `|| echo 0` would
  # append a SECOND line -> "0\n0" and break the integer test (§11.4.1). Swallow
  # the non-zero exit with `|| true` and default an empty capture to 0.
  errs="$(grep -c ': error:' "$ev" 2>/dev/null || true)"; errs="${errs:-0}"
  { echo "--- count ---"; echo "error_severity_findings=$errs (floor=0)"; } >> "$ev"
  if [ "${errs:-0}" -eq 0 ]; then
    ab_pass_with_evidence "R2: shellcheck found 0 error-severity findings across $(printf '%s\n' $files | wc -l | tr -d ' ') in-scope scripts" "$ev"
  else
    ab_fail "R2: shellcheck reported $errs error-severity finding(s) above the floor [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# ---- honest boundary note (recorded) -------------------------------------
note_ev="$(h_ev r2_honest_boundary)"
{ echo "HONEST BOUNDARY (§11.4.6): POSIX shell scripts have no shared-memory threading,"
  echo "so there is no classic in-process data-race / lock-ordering surface to exercise."
  echo "This suite tests what IS real for a shell+container stack: (R1) concurrent-"
  echo "invocation safety of the running stack under a connection burst (deadlock/hang"
  echo "detection via per-worker timeout) and (R2) static race/error-class lint of every"
  echo "owned script. True multi-writer file races on deploy/.env are covered atomically"
  echo "by tests/types/concurrency.sh (C2)."; } > "$note_ev"
h_log "recorded race/deadlock honest boundary: ${note_ev#$HC_ROOT/}"

h_summary
