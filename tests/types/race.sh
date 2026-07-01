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
  (
    code="$(timeout "$PTIMEOUT" curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "$HC_BASE$path" 2>/dev/null)"
    rc=$?
    printf 'w%s path=%s rc=%s code=%s\n' "$i" "$path" "$rc" "${code:-000}" > "$wdir/w$i.txt"
  ) &
  pids="$pids $!"
done
for p in $pids; do wait "$p" 2>/dev/null || true; done

completed=0; hung=0; noresp=0; live=0
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
  case "$line" in *"code=000"*) noresp=$((noresp+1));; *"code=2"*|*"code=3"*) live=$((live+1));; esac
done
{ echo "--- totals ---"
  echo "completed=$completed/$NPROBE hung(rc=124)=$hung no_response(code=000)=$noresp live(2xx/3xx)=$live"; } >> "$ev"

if [ "$completed" -eq "$NPROBE" ] && [ "$hung" -eq 0 ] && [ "$noresp" -eq 0 ] && [ "$live" -ge 1 ]; then
  ab_pass_with_evidence "R1: $completed/$NPROBE concurrent probes all completed, 0 hung, 0 no-response ($live live) — no deadlock" "$ev"
else
  ab_fail "R1: probe burst not clean (completed=$completed hung=$hung noresp=$noresp live=$live) [ev: ${ev#$HC_ROOT/}]"
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
