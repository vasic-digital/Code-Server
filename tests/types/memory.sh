#!/usr/bin/env bash
# tests/types/memory.sh — HelixCode MEMORY soak suite (§11.4.169 memory ; §12.6).
#
# Purpose:      Sample the resident memory of the two stack containers over a
#               bounded window under light request load and prove, with REAL
#               captured time-series evidence:
#                 (M1) code-server RSS stays BOUNDED (no monotonic unbounded
#                      growth — max <= min * GROWTH_FACTOR and under a ceiling).
#                 (M2) caddy RSS stays BOUNDED (same discipline).
#                 (M3) the PROJECT stack's own RSS stays under 60% of total
#                      host memory (§12.6 — OUR procedures' budget, not other
#                      workloads', §11.4.174); total host pct recorded as context.
#               The observer itself is light: a read-only `podman stats
#               --no-stream` snapshot per interval + a few cheap /healthz GETs
#               to keep the containers active (§12.6-friendly, §11.4.119 read-only).
# Usage:        bash tests/types/memory.sh
#               HC_MEM_SAMPLES=12 HC_MEM_INTERVAL=5 bash tests/types/memory.sh
# Inputs:       deploy/.env via the fixture ; HC_MEM_SAMPLES / HC_MEM_INTERVAL
# Outputs:      per-run evidence under qa-results/tests/memory/<run-id>/
# Side-effects: read-only stats + read-only HTTP; never mutates the shared stack.
# Dependencies: bash, podman|docker (stats), curl, awk, free
# Cross-references: §11.4.169 §11.4.24 §11.4.119 §12.6 §11.4.174 ; harness.sh stack_fixture.sh
#
# §1.1 PAIRED MUTATION (per case, for the meta-test sweep):
#   M1/M2 set GROWTH_FACTOR below 1.0 (e.g. 0.5) OR seed a fake monotonically-
#         doubling series -> max > min*factor -> the "RSS bounded" assert FAILs.
#   M3    set HOST_CEIL=0 -> our stack's usage pct (>=0) is never < 0 -> the
#         "stack under §12.6 budget" assert FAILs.
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init memory

# §11.4.1 / §11.4.90 — SUPERSEDED. Samples RSS of the RETIRED two-container model
# (deploy_code-server_1 + caddy); on the 2026-07-01 host-native SSH-key auth-pivot
# stack code-server runs host-native (no container to `podman stats`), so it is
# superseded by memory_auth. The old container is gone, so M1 would FALSE-FAIL —
# SKIP-with-reason (§11.4.6 detection). On the OLD stack it still runs unchanged.
if hc_legacy_model_retired; then
  ab_skip_with_reason "memory suite: superseded by memory_auth — legacy container+password model retired (see docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md)" topology_unsupported
  h_summary; exit $?
fi

SAMPLES="${HC_MEM_SAMPLES:-12}"
INTERVAL="${HC_MEM_INTERVAL:-5}"
GROWTH_FACTOR="15"     # tenths: 15 => max must be <= min * 1.5 (no unbounded growth)
CEIL_MB="1024"         # absolute RSS ceiling per container (calibrated: baseline ~106MB)
HOST_CEIL="60"         # §12.6 host memory budget ceiling (percent)

# ---- runtime guard -------------------------------------------------------
if ! h_require podman && ! h_require docker; then
  ab_skip_with_reason "memory suite (no container runtime for stats)" topology_unsupported
  h_summary; exit $?
fi
if ! h_require awk || ! h_require free; then
  ab_skip_with_reason "memory suite (awk/free absent)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi

# normalize a podman MemUsage 'used' token (e.g. 105.7MB / 29.9MB / 1.2GB / 512kB)
# to MiB (integer). Consistency across samples matters more than decimal-vs-binary
# exactness for a boundedness assertion (documented approximation).
to_mib() {
  awk -v s="${1:-0}" 'BEGIN{
    num=s; sub(/[A-Za-z]+$/,"",num); num=num+0;
    u=s; gsub(/[0-9.]+/,"",u); u=tolower(u);
    m=1;
    if(u=="b")            m=1/1048576;
    else if(u=="kb"||u=="kib") m=1/1024;
    else if(u=="mb"||u=="mib") m=1;
    else if(u=="gb"||u=="gib") m=1024;
    printf "%d", (num*m)+0.5;
  }'
}

CS_SERIES="$(h_ev m_series_code_server)"
CD_SERIES="$(h_ev m_series_caddy)"
HOST_SERIES="$(h_ev m_series_host)"
: > "$CS_SERIES"; : > "$CD_SERIES"; : > "$HOST_SERIES"

h_head "memory soak: $SAMPLES samples @ ${INTERVAL}s under light load"
cs_min=""; cs_max=""; cd_min=""; cd_max=""; host_max=0; cs_ok=0; cd_ok=0
n=0
while [ "$n" -lt "$SAMPLES" ]; do
  n=$((n+1))
  # light load: 3 cheap read-only GETs (keeps containers active, observer-light)
  hc_https_code /healthz >/dev/null 2>&1
  hc_https_code /login   >/dev/null 2>&1
  hc_https_code /        >/dev/null 2>&1

  raw="$("$HC_ENGINE" stats --no-stream --format '{{.Name}}|{{.MemUsage}}' "$HC_CS" "$HC_CADDY" 2>/dev/null)"
  cs_used="$(printf '%s\n' "$raw" | grep -F "$HC_CS"    | head -1 | awk -F'|' '{print $2}' | awk '{print $1}')"
  cd_used="$(printf '%s\n' "$raw" | grep -F "$HC_CADDY" | head -1 | awk -F'|' '{print $2}' | awk '{print $1}')"
  cs_mib="$(to_mib "$cs_used")"; cd_mib="$(to_mib "$cd_used")"
  host_pct="$(free -b | awk '/^Mem:/{printf "%d",(($3/$2)*100)+0.5}')"

  printf 'sample=%s used=%s mib=%s\n' "$n" "${cs_used:-?}" "$cs_mib" >> "$CS_SERIES"
  printf 'sample=%s used=%s mib=%s\n' "$n" "${cd_used:-?}" "$cd_mib" >> "$CD_SERIES"
  printf 'sample=%s host_used_pct=%s\n' "$n" "$host_pct" >> "$HOST_SERIES"

  # only fold POSITIVE samples into min/max (a transient empty read must not
  # collapse min to 0 and false-FAIL the boundedness check, §11.4.6).
  if [ "${cs_mib:-0}" -gt 0 ]; then
    cs_ok=$((cs_ok+1))
    [ -z "$cs_min" ] && { cs_min="$cs_mib"; cs_max="$cs_mib"; }
    [ "$cs_mib" -lt "$cs_min" ] && cs_min="$cs_mib"; [ "$cs_mib" -gt "$cs_max" ] && cs_max="$cs_mib"
  fi
  if [ "${cd_mib:-0}" -gt 0 ]; then
    cd_ok=$((cd_ok+1))
    [ -z "$cd_min" ] && { cd_min="$cd_mib"; cd_max="$cd_mib"; }
    [ "$cd_mib" -lt "$cd_min" ] && cd_min="$cd_mib"; [ "$cd_mib" -gt "$cd_max" ] && cd_max="$cd_mib"
  fi
  [ "${host_pct:-0}" -gt "$host_max" ] && host_max="$host_pct"

  h_log "sample $n/$SAMPLES: code-server=${cs_mib}MiB caddy=${cd_mib}MiB host=${host_pct}%"
  [ "$n" -lt "$SAMPLES" ] && sleep "$INTERVAL"
done

# bounded check: max <= min * (GROWTH_FACTOR/10) AND max < CEIL_MB
bounded() { # <min> <max> ; uses GROWTH_FACTOR tenths + CEIL_MB
  awk -v mn="$1" -v mx="$2" -v g="$GROWTH_FACTOR" -v ceil="$CEIL_MB" \
    'BEGIN{ lim = mn*(g/10.0); exit !((mx <= lim) && (mx < ceil)); }'
}

# ---- M1 code-server bounded ----------------------------------------------
{ echo "--- summary ---"; echo "code-server MiB: min=$cs_min max=$cs_max limit=min*${GROWTH_FACTOR}/10 ceil=$CEIL_MB valid_samples=$cs_ok"; } >> "$CS_SERIES"
if [ -n "$cs_min" ] && [ "$cs_ok" -ge "$((SAMPLES/2))" ] && bounded "$cs_min" "$cs_max"; then
  ab_pass_with_evidence "M1: code-server RSS bounded over $SAMPLES samples (min=${cs_min}MiB max=${cs_max}MiB, no unbounded growth)" "$CS_SERIES"
else
  ab_fail "M1: code-server RSS unbounded/over-ceiling (min=${cs_min} max=${cs_max} ceil=$CEIL_MB) [ev: ${CS_SERIES#$HC_ROOT/}]"
fi

# ---- M2 caddy bounded ----------------------------------------------------
{ echo "--- summary ---"; echo "caddy MiB: min=$cd_min max=$cd_max limit=min*${GROWTH_FACTOR}/10 ceil=$CEIL_MB valid_samples=$cd_ok"; } >> "$CD_SERIES"
if [ -n "$cd_min" ] && [ "$cd_ok" -ge "$((SAMPLES/2))" ] && bounded "$cd_min" "$cd_max"; then
  ab_pass_with_evidence "M2: caddy RSS bounded over $SAMPLES samples (min=${cd_min}MiB max=${cd_max}MiB, no unbounded growth)" "$CD_SERIES"
else
  ab_fail "M2: caddy RSS unbounded/over-ceiling (min=${cd_min} max=${cd_max} ceil=$CEIL_MB) [ev: ${CD_SERIES#$HC_ROOT/}]"
fi

# ---- M3 OUR stack under §12.6 60% of total host (not other workloads) ------
# §12.6 budgets the PROJECT's procedures, not the whole host — so basing the
# gate on total host pct would let unrelated operator workloads (§11.4.174)
# spuriously block a tag. Assert OUR stack's peak RSS as a fraction of total
# host RAM; record total host pct as context only.
host_total_mib="$(free -m | awk '/^Mem:/{print $2}')"
our_peak_mib=$(( ${cs_max:-0} + ${cd_max:-0} ))
our_pct="$(awk -v p="$our_peak_mib" -v t="${host_total_mib:-1}" 'BEGIN{ if(t<=0)t=1; printf "%d",((p/t)*100)+0.5 }')"
{ echo "--- summary ---"
  echo "OUR stack peak RSS = ${our_peak_mib}MiB (code-server ${cs_max:-0} + caddy ${cd_max:-0}) of ${host_total_mib}MiB host"
  echo "OUR usage = ${our_pct}% of total host memory ; §12.6 ceiling = ${HOST_CEIL}%"
  echo "context: total host used (ALL workloads incl. others, §11.4.174) peaked at ${host_max}%"; } >> "$HOST_SERIES"
if [ "${our_pct:-100}" -lt "$HOST_CEIL" ]; then
  ab_pass_with_evidence "M3: HelixCode stack used ${our_pct}% of host memory (< §12.6 ${HOST_CEIL}% budget; peak ${our_peak_mib}MiB)" "$HOST_SERIES"
else
  ab_fail "M3: HelixCode stack used ${our_pct}% of host memory (>= §12.6 ${HOST_CEIL}% budget; peak ${our_peak_mib}MiB) [ev: ${HOST_SERIES#$HC_ROOT/}]"
fi

h_summary
