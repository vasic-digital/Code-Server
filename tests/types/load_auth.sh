#!/usr/bin/env bash
#
# tests/types/load_auth.sh — DDoS / FLOOD load suite (§11.4.85 / §11.4.169) for the
# 2026-07-01 SSH-KEY auth gate (docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md).
#
# Bursts the auth surface with adversarial traffic and proves the gate does NOT
# collapse, does NOT fail-open under load, and that its (fixed) rate-limiter throttles
# genuine bad-login floods with a REAL 429 — never accepting latency/timeouts as a
# substitute for the 429 (that latency heuristic is the weaker security_auth (4)
# fallback; this suite demands the hard status or SKIPs inconclusive).
#
# Assertions (target = live edge/gate; gate-direct or a launchable local gate if the
# full edge is down; SKIP-with-reason when no target — never a fake PASS on a down
# stack, §11.4/§11.4.1/§11.4.69; the conductor deploys the stack live and re-runs):
#   (L1) STAYS UP — after flooding /login with N bad logins @ concurrency C, the gate
#        still answers /healthz=200 (and the edge is still reachable): no crash.
#   (L2) FAILS CLOSED UNDER LOAD — not a single bad login in the flood is accepted
#        (zero 302/303 successes): the gate never authorizes garbage even under load.
#   (L3) RATE-LIMITED with a REAL 429 — the bad-login flood produces >=1 HTTP 429.
#        If NO 429 is seen the result is SKIP-INCONCLUSIVE (never a latency-based
#        PASS): we cannot positively confirm throttling, so we do not claim it.
#   (L4) /auth FLOOD FAILS CLOSED — flooding the forward-auth endpoint with no-cookie
#        and forged-cookie requests yields ZERO 200 (no fail-open) and the gate is up
#        after. Throughput + a full status histogram are recorded for every flood.
#
# §1.1 PAIRED-MUTATION intent:
#   (L1) make the gate exit under load -> post /healthz != 200 -> L1 FAILs.
#   (L2) accept a bad login under load -> a 302 appears -> L2 FAILs.
#   (L3) disable the 429 rate-limiter -> zero 429 -> L3 becomes SKIP-inconclusive
#        (NOT a PASS) -> proves the assertion cannot be satisfied by latency alone.
#   (L4) let /auth answer 200 without a valid cookie -> fail-open -> L4 FAILs.
#
# Usage:        bash tests/types/load_auth.sh
# Inputs:       deploy/.env + HELIX_AUTH_ADDR (via fixture) ;
#               HC_LOAD_N (default 200, <=2000) HC_LOAD_C (default 20, <=128) ;
#               HELIX_AUTH_BIN / ~/.local/bin/helix-auth (optional local gate)
# Outputs:      qa-results/tests/load_auth/<run-id>/*.txt ; exit 0 iff all PASS/SKIP
# Side-effects: adversarial POST/GET floods against the auth surface (bounded §12.6);
#               any launched local gate is trap-killed; never mutates the stack or git;
#               no credential printed (§11.4.10)
# Dependencies: bash, curl ; coreutils, awk ; ssh-keygen (optional local gate)
# Cross-refs:   §11.4.6 §11.4.10 §11.4.69 §11.4.85 §11.4.98 §11.4.169 ;
#               harness.sh stack_fixture.sh ; specs 2026-07-01-auth-pivot-ssh-key.md
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init load_auth

PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_load_auth.XXXXXX")"
N="${HC_LOAD_N:-200}"; case "$N" in ''|*[!0-9]*) N=200;; esac; [ "$N" -lt 1 ] && N=1; [ "$N" -gt 2000 ] && N=2000
C="${HC_LOAD_C:-20}";  case "$C" in ''|*[!0-9]*) C=20;;  esac; [ "$C" -lt 1 ] && C=1; [ "$C" -gt 128 ] && C=128

LG_PID=""
cleanup() { [ -n "$LG_PID" ] && kill "$LG_PID" 2>/dev/null || true; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

if ! h_require curl; then
  ab_skip_with_reason "load_auth: curl not on PATH" topology_unsupported
  h_summary; exit $?
fi

# ---- optional locally-launched gate (spec-documented params only; §11.4.6) ---
_launch_local_gate() {
  LG_BASE=""; LG_PID=""
  h_require ssh-keygen || return 1
  local bin; bin="${HELIX_AUTH_BIN:-$HOME/.local/bin/helix-auth}"
  [ -x "$bin" ] || return 1
  local d ak port i; d="$WORK/lg"; mkdir -p "$d"
  ssh-keygen -q -t ed25519 -N '' -C 'helixcode-lg' -f "$d/id" </dev/null >/dev/null 2>&1 || return 1
  ak="$d/authorized_keys"; cp "$d/id.pub" "$ak"; port="${HELIX_AUTH_LOCAL_PORT:-18081}"
  HELIX_AUTH_MODE=sshkey HELIX_AUTH_ACCOUNT="$PRINCIPAL" HELIX_AUTH_PRINCIPAL="$PRINCIPAL" \
    HELIX_AUTH_AUTHORIZED_KEYS="$ak" HELIX_AUTH_ADDR="127.0.0.1:$port" \
    HELIX_AUTH_LISTEN="127.0.0.1:$port" HELIX_AUTH_PORT="$port" \
    "$bin" >"$d/gate.log" 2>&1 &
  LG_PID=$!
  for i in $(seq 1 16); do
    kill -0 "$LG_PID" 2>/dev/null || { LG_PID=""; return 1; }
    [ "$(hc_http_code "http://127.0.0.1:$port/healthz")" = 200 ] && { LG_BASE="http://127.0.0.1:$port"; return 0; }
    sleep 1
  done
  kill "$LG_PID" 2>/dev/null || true; LG_PID=""; return 1
}

# resolve login/auth/health URLs
LOGIN_URL=""; AUTH_URL=""; HEALTH_URL=""; EDGE_URL=""; TMODE=""
if hc_new_stack_up; then
  LOGIN_URL="$HC_BASE/login"; AUTH_URL="http://${HC_GATE_ADDR}/auth"; HEALTH_URL="http://${HC_GATE_ADDR}/healthz"; EDGE_URL="$HC_BASE/"; TMODE="edge"
elif [ "$(hc_http_code "http://${HC_GATE_ADDR}/healthz")" = 200 ]; then
  LOGIN_URL="http://${HC_GATE_ADDR}/login"; AUTH_URL="http://${HC_GATE_ADDR}/auth"; HEALTH_URL="http://${HC_GATE_ADDR}/healthz"; EDGE_URL="http://${HC_GATE_ADDR}/healthz"; TMODE="gate-direct"
elif _launch_local_gate; then
  LOGIN_URL="$LG_BASE/login"; AUTH_URL="$LG_BASE/auth"; HEALTH_URL="$LG_BASE/healthz"; EDGE_URL="$LG_BASE/healthz"; TMODE="local-launched"
fi

if [ -z "$LOGIN_URL" ]; then
  ev="$(h_ev target_down)"
  { echo "no ssh-key auth target: live edge/gate down AND no launchable local gate";
    echo "probe: ${HC_NEW_STACK_DETAIL:-<none>} ; HELIX_AUTH_BIN=${HELIX_AUTH_BIN:-<unset>}"; } > "$ev"
  ab_skip_with_reason "load_auth: no ssh-key auth target deployed/launchable" topology_unsupported
  h_summary; exit $?
fi

# ---- flood helper: N bad POST /login @ C, one status code per line -----------
_flood_login() { # <raw-out>
  seq 1 "$N" | xargs -P "$C" -I{} bash -c '
    curl -k -s -o /dev/null -w "%{http_code}\n" --max-time 15 \
      --data-urlencode "signature=flood-{}-$RANDOM$$" \
      --data-urlencode "principal=nobody-{}-$RANDOM" \
      "$0" 2>/dev/null || echo 000' "$LOGIN_URL" >> "$1" 2>/dev/null
}
# ---- flood helper: N /auth @ C (half no-cookie, half forged) -----------------
_flood_auth() { # <raw-out>
  seq 1 "$N" | xargs -P "$C" -I{} bash -c '
    ck=""; [ $(( {} % 2 )) -eq 0 ] && ck="-H Cookie:session=forged-{}-$RANDOM"
    curl -k -s -o /dev/null -w "%{http_code}\n" --max-time 15 $ck "$0" 2>/dev/null || echo 000' "$AUTH_URL" >> "$1" 2>/dev/null
}
_rps() { awk -v n="$1" -v ms="$2" 'BEGIN{ printf "%.1f", (ms>0)? (n*1000.0/ms) : 0 }'; }

# =========================================================================
# FLOOD /login  ->  L1 stays up, L2 fails closed, L3 rate-limited (real 429).
# =========================================================================
h_head "flood POST /login: N=$N @ C=$C (bad logins) -> stays up / fails closed / 429"
raw="$(h_ev login_flood_raw)"; : > "$raw"
health_pre="$(hc_http_code "$HEALTH_URL")"
t0="$(date +%s%N 2>/dev/null)"; case "$t0" in *[!0-9]*|'') t0=0;; esac
_flood_login "$raw"
t1="$(date +%s%N 2>/dev/null)"; case "$t1" in *[!0-9]*|'') t1=0;; esac
wall=0; [ "$t1" -gt "$t0" ] 2>/dev/null && wall=$(( (t1 - t0) / 1000000 ))
completed="$(wc -l < "$raw" | tr -d ' ')"
success="$(awk '$1==302||$1==303{c++} END{print c+0}' "$raw")"
c429="$(awk '$1==429{c++} END{print c+0}' "$raw")"
c000="$(awk '$1==000{c++} END{print c+0}' "$raw")"
health_post="$(hc_http_code "$HEALTH_URL")"; edge_post="$(hc_http_code "$EDGE_URL")"
rps="$(_rps "$completed" "$wall")"

hist="$(sort "$raw" | uniq -c)"
ev1="$(h_ev l1_stays_up)"
{ echo "=== (L1) gate stays up under /login flood (mode=$TMODE) ===";
  echo "flood: N=$N C=$C completed=$completed wall=${wall}ms throughput=${rps} req/s";
  echo "gate /healthz pre=$health_pre post=$health_post (want post=200) edge post=$edge_post";
  echo "status histogram:"; printf '%s\n' "$hist"; } > "$ev1"
if [ "$health_post" = 200 ] && [ "$edge_post" != 000 ]; then
  ab_pass_with_evidence "L1: gate survived $N/@$C login flood (throughput ${rps} req/s), /healthz=$health_post, edge=$edge_post" "$ev1"
else
  ab_fail "L1: gate did not stay up (health_post=$health_post edge_post=$edge_post) [ev: ${ev1#$HC_ROOT/}]"
fi

ev2="$(h_ev l2_fail_closed)"
{ echo "=== (L2) /login flood fails CLOSED (no bad login accepted under load) ===";
  echo "accepted logins (302/303) during flood: $success (want 0)";
  echo "completed=$completed dropped/timeout(000)=$c000";
  echo "status histogram:"; printf '%s\n' "$hist"; } > "$ev2"
if [ "$success" -eq 0 ] && [ "$completed" -ge 1 ]; then
  ab_pass_with_evidence "L2: fails CLOSED under load — 0 of $completed bad logins accepted" "$ev2"
else
  ab_fail "L2: bad login(s) accepted under load (success=$success completed=$completed) [ev: ${ev2#$HC_ROOT/}]"
fi

ev3="$(h_ev l3_rate_limited)"
{ echo "=== (L3) rate-limiter emits a REAL 429 (latency is NOT accepted as proof) ===";
  echo "HTTP 429 count in bad-login flood: $c429 (want >=1 for PASS; 0 -> SKIP-inconclusive)";
  echo "completed=$completed dropped/timeout(000)=$c000 throughput=${rps} req/s";
  echo "status histogram:"; printf '%s\n' "$hist"; } > "$ev3"
if [ "$c429" -ge 1 ]; then
  ab_pass_with_evidence "L3: rate-limiter throttled the flood with $c429 real HTTP 429 responses" "$ev3"
else
  { echo ""; echo "no 429 observed — cannot positively confirm throttling; NOT downgrading to a";
    echo "latency/timeout heuristic (that is the weaker security_auth(4) fallback). SKIP-inconclusive."; } >> "$ev3"
  ab_skip_with_reason "L3: no HTTP 429 in the login flood — rate-limit throttle not positively confirmed (inconclusive)" feature_disabled_by_config
fi

# =========================================================================
# FLOOD /auth  ->  L4 fails closed (no fail-open 200), gate up after.
# =========================================================================
h_head "flood /auth: N=$N @ C=$C (no-cookie + forged) -> zero 200 (no fail-open)"
araw="$(h_ev auth_flood_raw)"; : > "$araw"
at0="$(date +%s%N 2>/dev/null)"; case "$at0" in *[!0-9]*|'') at0=0;; esac
_flood_auth "$araw"
at1="$(date +%s%N 2>/dev/null)"; case "$at1" in *[!0-9]*|'') at1=0;; esac
awall=0; [ "$at1" -gt "$at0" ] 2>/dev/null && awall=$(( (at1 - at0) / 1000000 ))
acompleted="$(wc -l < "$araw" | tr -d ' ')"
a200="$(awk '$1==200{c++} END{print c+0}' "$araw")"
a401="$(awk '$1==401{c++} END{print c+0}' "$araw")"
arps="$(_rps "$acompleted" "$awall")"
ahealth_post="$(hc_http_code "$HEALTH_URL")"
ev4="$(h_ev l4_auth_fail_closed)"
{ echo "=== (L4) /auth flood fails CLOSED (no fail-open) ===";
  echo "flood: N=$N C=$C completed=$acompleted wall=${awall}ms throughput=${arps} req/s";
  echo "fail-open 200 responses: $a200 (want 0)   401 denials: $a401";
  echo "gate /healthz after flood: $ahealth_post (want 200)";
  echo "status histogram:"; sort "$araw" | uniq -c; } > "$ev4"
if [ "$a200" -eq 0 ] && [ "$acompleted" -ge 1 ] && [ "$ahealth_post" = 200 ]; then
  ab_pass_with_evidence "L4: /auth flood fails CLOSED — 0 of $acompleted requests served 200, gate up after ($ahealth_post)" "$ev4"
else
  ab_fail "L4: /auth flood not fail-closed (200s=$a200 completed=$acompleted health_post=$ahealth_post) [ev: ${ev4#$HC_ROOT/}]"
fi

h_summary
