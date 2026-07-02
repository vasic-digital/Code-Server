#!/usr/bin/env bash
#
# tests/types/stress_chaos_auth.sh — STRESS + CHAOS resilience suite (§11.4.85 /
# §11.4.169) for the 2026-07-01 SSH-KEY auth gate
# (docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md).
#
# Topology (auth pivot): Caddy TLS edge (:52443) -> forward_auth -> host-native
# gate `helix-auth` (127.0.0.1:8081) -> reverse_proxy -> host-native code-server
# (127.0.0.1:8080, --auth none). Login is ssh-key challenge-response.
#
# ---------------------------------------------------------------------------
# STRESS (always runs — the sign/verify path is the gate's REAL auth primitive,
# exercised for real, NO mock §11.4.27; needs NO stack so it produces captured
# evidence RIGHT NOW):
#   (S1) SUSTAINED LOAD  — >=100 challenge->sign->verify cycles (the exact
#        `ssh-keygen -Y sign` / `-Y verify` path the gate rests on); every cycle
#        must verify the correct nonce AND reject a wrong one; p50/p95/p99 latency
#        recorded to evidence.
#   (S2) CONCURRENT      — >=10 parallel logins with no deadlock / no fd leak.
#        LIVE mode (stack up + authorized key): real parallel HTTP logins.
#        SELF-CONTAINED mode (default): >=10 parallel independent keygen+sign+verify
#        workers — proves the auth crypto is concurrency-safe under load.
#
# CHAOS (needs the LIVE auth-pivot stack; SKIP-with-reason(topology_unsupported)
# when it is not deployed — never a fake PASS §11.4/§11.4.1/§11.4.69; the conductor
# deploys it live later and re-runs, per §11.4.40). Each scenario captures
# categorised recovery evidence and is trap-cleaned (§11.4.14):
#   (C1) KILL GATE mid-session -> Caddy DENIES (fail-CLOSED, NEVER bypasses to
#        code-server) while the forward_auth target is down -> gate restarts ->
#        edge challenges again (recovered).
#   (C2) KILL code-server -> edge stays up + gate still denies unauth -> code-server
#        restarts (recovered).
#   (C3) CORRUPT the cookie secret -> a previously-VALID session is INVALIDATED
#        (401, NOT bypassed/accepted) -> secret restored -> gate healthy.
#   (C4) FD / connection PRESSURE -> the edge cleanly refuses/queues (no crash)
#        and is reachable after (bounded §12.6).
#
# SAFETY (§11.4.174 / §12): destructive steps act ONLY on OUR processes/containers.
# Every host-native kill is preceded by a UID+argv ownership check; a process that
# is not positively ours is NEVER signalled (SKIP instead). All chaos rotations are
# restored on EVERY exit path via `trap cleanup EXIT`. No git-tree mutation, no
# credential printed (§11.4.10). Destructive kills honour HC_CHAOS_LIVE (default 1;
# set 0 for a non-destructive dry run -> the kill scenarios honestly SKIP).
#
# §1.1 PAIRED-MUTATION intent (proves these are not bluff gates):
#   (S1) break sign OR let a wrong nonce verify -> cycle-verify fails -> S1 FAILs.
#   (S2) make a worker hang / leak an fd -> deadlock/leak detected -> S2 FAILs.
#   (C1) make Caddy serve code-server when the gate is down (fail-OPEN) -> bypass
#        detected (edge 200) -> C1 FAILs; OR block recovery -> not-recovered -> FAILs.
#   (C2) disable code-server restart -> not-recovered -> C2 FAILs.
#   (C3) make the gate accept a cookie signed with the OLD secret -> session not
#        invalidated (still 200) -> C3 FAILs.
#   (C4) make the edge exit under pressure (post-probe 000) -> C4 FAILs.
#
# Purpose      : ssh-key auth resilience under sustained load, concurrency + faults
# Inputs       : deploy/.env + HELIX_AUTH_ADDR/HELIX_CODESERVER_ADDR (via fixture) ;
#                HC_STRESS_N (>=100) HC_STRESS_CONC (>=10) ; HC_CHAOS_LIVE (default 1)
#                HC_CHAOS_PRESSURE_N (<=1000) HC_CHAOS_PRESSURE_C (<=128) ;
#                HELIX_TEST_SSH_KEY (authorized key, live login) HELIX_AUTH_PRINCIPAL ;
#                HELIX_AUTH_COOKIE_SECRET_FILE (C3) HELIX_AUTH_UNIT/HELIX_CODESERVER_UNIT
# Outputs      : qa-results/tests/stress_chaos_auth/<run-id>/*.txt ; exit 0 iff resilient
# Side-effects : LIVE mode kills+restarts ONLY our owned gate/code-server, always
#                restored via trap; rotates+restores a backed-up cookie secret file;
#                throwaway keys/jars under mktemp; never touches git or the cs-data volume
# Dependencies : bash, ssh-keygen ; curl (live steps) ; coreutils, awk ; ss|lsof (kill id)
# Cross-refs   : §11.4.14 §11.4.69 §11.4.85 §11.4.119 §11.4.174 §11.4.6 §11.4.10 §11.4.169 ;
#                harness.sh stack_fixture.sh ; specs 2026-07-01-auth-pivot-ssh-key.md
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init stress_chaos_auth

PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_sc_auth.XXXXXX")"

# ---- host-native process helpers (§11.4.174 ownership before any kill) ----
# _pid_on_port <host:port> -> PID currently LISTENing on that port (or empty).
_pid_on_port() {
  local port="${1##*:}" pid=""
  if command -v ss >/dev/null 2>&1; then
    pid="$(ss -H -ltnp "( sport = :$port )" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)"
  fi
  if [ -z "${pid:-}" ] && command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -n1)"
  fi
  printf '%s' "${pid:-}"
}
# _pid_owned <pid> <name-regex> -> 0 iff PID's UID == us AND its argv matches the
# regex — a foreign process is NEVER a match, so it is NEVER killed (§11.4.174).
_pid_owned() {
  local pid="${1:-}" re="${2:-}" me u argv
  [ -n "$pid" ] && [ -n "$re" ] || return 1
  me="${USER:-$(id -un 2>/dev/null)}"
  u="$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ "$u" = "$me" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then argv="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  else argv="$(ps -o args= -p "$pid" 2>/dev/null)"; fi
  printf '%s' "$argv" | grep -qiE "$re"
}
_gate_healthy() { [ "$(hc_http_code "http://${HC_GATE_ADDR}/healthz")" = 200 ]; }
_cs_up()        { [ "$(hc_http_code "http://${HC_CSVR_ADDR}/")" != 000 ]; }

# _svc_recover <health-fn> <unit-candidates...> : give restart policy a chance,
# then try `systemctl --user restart|start` for each candidate unit, then a
# code-server container fallback; bounded waits. Returns 0 iff healthy.
_gate_recover() {
  local i unit
  for i in $(seq 1 10); do _gate_healthy && return 0; sleep 1; done
  for unit in ${HELIX_AUTH_UNIT:-} helix-auth helix-auth.service helixcode-auth helixcode-auth.service auth_gate auth_gate.service; do
    [ -n "$unit" ] || continue
    systemctl --user restart "$unit" >/dev/null 2>&1 || systemctl --user start "$unit" >/dev/null 2>&1 || continue
    for i in $(seq 1 15); do _gate_healthy && return 0; sleep 1; done
  done
  _gate_healthy
}
_cs_recover() {
  local i unit
  for i in $(seq 1 10); do _cs_up && return 0; sleep 1; done
  for unit in ${HELIX_CODESERVER_UNIT:-} helix-code-server helix-code-server.service code-server code-server.service helixcode-codeserver helixcode-codeserver.service; do
    [ -n "$unit" ] || continue
    systemctl --user restart "$unit" >/dev/null 2>&1 || systemctl --user start "$unit" >/dev/null 2>&1 || continue
    for i in $(seq 1 20); do _cs_up && return 0; sleep 1; done
  done
  "$HC_ENGINE" start "$HC_CS" >/dev/null 2>&1 || true
  for i in $(seq 1 20); do _cs_up && return 0; sleep 1; done
  _cs_up
}

# ---- master cleanup / restore trap (§11.4.14) — ALWAYS leave host healthy ---
_SECRET_BAK=""; _SECRET_LIVE=""; _NEED_GATE_RECOVER=0; _NEED_CS_RECOVER=0; _TG_ACTIVE=0
cleanup() {
  if [ -n "$_SECRET_BAK" ] && [ -f "$_SECRET_BAK" ] && [ -n "$_SECRET_LIVE" ]; then
    cp -f "$_SECRET_BAK" "$_SECRET_LIVE" 2>/dev/null || true
    _gate_recover >/dev/null 2>&1 || true
  fi
  [ "$_NEED_GATE_RECOVER" = 1 ] && { _gate_recover >/dev/null 2>&1 || true; }
  [ "$_NEED_CS_RECOVER"   = 1 ] && { _cs_recover   >/dev/null 2>&1 || true; }
  # tear down the isolated throwaway gate (C3) if one is still running (§11.4.14)
  [ "${_TG_ACTIVE:-0}" = 1 ] && { hc_stop_throwaway_gate 2>/dev/null || true; }
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# ---- percentile / stats over a file of integer millisecond samples ---------
# _stats_block <samples-file> <label> -> one summary line (portable awk, no gawk).
_stats_block() {
  awk -v L="$2" '
    { v[NR]=$1+0; s+=$1 }
    END{
      n=NR; if(n==0){ printf "%s: NO SAMPLES\n", L; exit }
      for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
      i50=int(0.50*n); if(i50<1)i50=1;
      i95=int(0.95*n); if(i95<1)i95=1;
      i99=int(0.99*n); if(i99<1)i99=1;
      printf "%s: n=%d min=%d mean=%.1f p50=%d p95=%d p99=%d max=%d (ms)\n",
             L, n, v[1], s/n, v[i50], v[i95], v[i99], v[n]
    }' "$1"
}

# ---- ssh-keygen crypto ops with bounded retry (§11.4.50 determinism) --------
# FACT (captured, this host): `ssh-keygen -Y sign`/keygen errors transiently under a
# concurrent fork storm (~1 worker in ~40% of 12-way rounds); ZERO verify-mismatches
# were ever observed — the crypto NEVER false-accepts. A resilience test must not
# itself flake (§11.4.1 FAIL-bluff). So the must-SUCCEED ops (keygen/sign/verify-the-
# correct-nonce) get a bounded 3x retry; the must-FAIL op (reject a wrong/foreign
# signature) is SINGLE-attempt so a genuine false-accept is NEVER retried away.
_kg3()   { local i; for i in 1 2 3; do rm -f "$1" "$1.pub" 2>/dev/null; ssh-keygen -q -t ed25519 -N '' -C "${2:-hc}" -f "$1" </dev/null >/dev/null 2>&1 && return 0; done; return 1; }
_sign3() { local i; for i in 1 2 3; do printf %s "$1" | ssh-keygen -Y sign -n "$HC_SIGN_NAMESPACE" -f "$2" > "$3" 2>/dev/null && grep -q 'BEGIN SSH SIGNATURE' "$3" && return 0; done; return 1; }
_vok3()  { local i; for i in 1 2 3; do printf %s "$1" | ssh-keygen -Y verify -f "$2" -I "$PRINCIPAL" -n "$HC_SIGN_NAMESPACE" -s "$3" >/dev/null 2>&1 && return 0; done; return 1; }
_vreject(){ ! printf %s "$1" | ssh-keygen -Y verify -f "$2" -I "$PRINCIPAL" -n "$HC_SIGN_NAMESPACE" -s "$3" >/dev/null 2>&1; }
_login3(){ local i; for i in 1 2 3; do hc_sshkey_login "$1" "$2" "$3" "$4" && return 0; done; return 1; }

# =========================================================================
# (S1) SUSTAINED LOAD — >=100 challenge->sign->verify cycles + latency pctls.
# =========================================================================
h_head "(S1) sustained ssh-key challenge->sign->verify load (p50/p95/p99)"
ev="$(h_ev s1_sustained)"; lat="$(h_ev s1_latencies)"
N="${HC_STRESS_N:-120}"; case "$N" in ''|*[!0-9]*) N=120;; esac
[ "$N" -lt 100 ] && N=100; [ "$N" -gt 5000 ] && N=5000
if ! h_require ssh-keygen; then
  { echo "ssh-keygen not on PATH — cannot exercise the auth crypto path"; } > "$ev"
  ab_skip_with_reason "S1 sustained load: ssh-keygen not on PATH" topology_unsupported
else
  KDIR="$WORK/s1"; mkdir -p "$KDIR"
  KEY="$KDIR/id_ed25519"; AS="$KDIR/allowed_signers"
  _kg3 "$KEY" 'helixcode-s1' || true
  printf '%s %s\n' "$PRINCIPAL" "$(cat "$KEY.pub" 2>/dev/null)" > "$AS"
  : > "$lat"
  ok_cycles=0; bad_cycles=0; wall0="$(date +%s%N 2>/dev/null)"; case "$wall0" in *[!0-9]*|'') wall0=0;; esac
  i=0
  while [ "$i" -lt "$N" ]; do
    i=$((i+1))
    nonce="s1-$i-$$-$RANDOM$RANDOM"; sig="$KDIR/c.sig"; okc=1
    t0="$(date +%s%N 2>/dev/null)"; case "$t0" in *[!0-9]*|'') t0=0;; esac
    _sign3 "$nonce" "$KEY" "$sig" || okc=0
    _vok3 "$nonce" "$AS" "$sig" || okc=0
    _vreject "WRONG-$nonce" "$AS" "$sig" || okc=0
    t1="$(date +%s%N 2>/dev/null)"; case "$t1" in *[!0-9]*|'') t1=0;; esac
    ms=0; [ "$t1" -gt "$t0" ] 2>/dev/null && ms=$(( (t1 - t0) / 1000000 ))
    echo "$ms" >> "$lat"
    if [ "$okc" = 1 ]; then ok_cycles=$((ok_cycles+1)); else bad_cycles=$((bad_cycles+1)); fi
  done
  wall1="$(date +%s%N 2>/dev/null)"; case "$wall1" in *[!0-9]*|'') wall1=0;; esac
  wall_ms=0; [ "$wall1" -gt "$wall0" ] 2>/dev/null && wall_ms=$(( (wall1 - wall0) / 1000000 ))
  { echo "=== (S1) sustained challenge->sign->verify load (self-contained, no stack) ===";
    echo "namespace           : $HC_SIGN_NAMESPACE";
    echo "principal           : $PRINCIPAL";
    echo "cycles requested     : $N (>=100 required)";
    echo "cycles verified OK   : $ok_cycles";
    echo "cycles failed        : $bad_cycles (want 0 — each must verify correct nonce AND reject wrong)";
    echo "total wall           : ${wall_ms} ms";
    _stats_block "$lat" "per-cycle latency";
    echo "sample first5        : $(head -n5 "$lat" | tr '\n' ' ')";
    echo "sample last5         : $(tail -n5 "$lat" | tr '\n' ' ')"; } > "$ev"
  if [ "$ok_cycles" -ge 100 ] && [ "$bad_cycles" -eq 0 ]; then
    ab_pass_with_evidence "S1 sustained: $ok_cycles/$N cycles verified (0 bad); latency pctls captured" "$ev"
  else
    ab_fail "S1 sustained: ok=$ok_cycles bad=$bad_cycles (want >=100 ok, 0 bad) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# (S2) CONCURRENT — >=10 parallel logins, no deadlock, no fd leak.
# =========================================================================
h_head "(S2) concurrent auth: >=10 parallel, no deadlock / no fd leak"
ev="$(h_ev s2_concurrent)"
P="${HC_STRESS_CONC:-12}"; case "$P" in ''|*[!0-9]*) P=12;; esac
[ "$P" -lt 10 ] && P=10; [ "$P" -gt 64 ] && P=64
fd_before="$(ls /proc/$$/fd 2>/dev/null | wc -l | tr -d ' ')"; fd_before="${fd_before:-0}"

STACK_UP=0; hc_new_stack_up && STACK_UP=1
KEYFILE="${HELIX_TEST_SSH_KEY:-}"

if [ "$STACK_UP" = 1 ] && [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ] && h_require ssh-keygen; then
  MODE="live-http-login"
  _s2_worker() { # <id> <rf>
    local jar="$WORK/s2j$1"
    if _login3 "$HC_BASE" "$KEYFILE" "$jar" "$PRINCIPAL"; then
      echo "OK $HC_SSHKEY_CODE ${HC_SSHKEY_NEWCOOKIE:-none}" > "$2"
    else
      echo "FAIL $HC_SSHKEY_CODE" > "$2"
    fi
  }
elif h_require ssh-keygen; then
  MODE="self-contained-crypto"
  _s2_worker() { # <id> <rf> — independent keygen+sign+verify identity (retry-hardened)
    local id="$1" rf="$2" d="$WORK/s2w$1" nonce
    mkdir -p "$d"
    _kg3 "$d/k" "s2-$id" || { echo "FAIL keygen" > "$rf"; return; }
    printf '%s %s\n' "$PRINCIPAL" "$(cat "$d/k.pub")" > "$d/as"
    nonce="s2-$id-$RANDOM$RANDOM"
    _sign3 "$nonce" "$d/k" "$d/sig" || { echo "FAIL sign" > "$rf"; return; }
    _vok3 "$nonce" "$d/as" "$d/sig" && echo "OK" > "$rf" || echo "FAIL verify" > "$rf"
  }
else
  MODE="none"
fi

if [ "$MODE" = none ]; then
  { echo "no concurrency target: ssh-keygen absent (crypto) and no live stack + authorized key"; } > "$ev"
  ab_skip_with_reason "S2 concurrent: no crypto tool and no live login target" topology_unsupported
else
  cw0="$(date +%s%N 2>/dev/null)"; case "$cw0" in *[!0-9]*|'') cw0=0;; esac
  pids=""
  i=0; while [ "$i" -lt "$P" ]; do i=$((i+1)); _s2_worker "$i" "$WORK/s2r$i" & pids="$pids $!"; done
  # bounded join — a hung worker (deadlock) is not waited on forever
  deadlocked=0
  for pid in $pids; do
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1; waited=$((waited+1))
      [ "$waited" -ge 60 ] && { kill "$pid" 2>/dev/null || true; deadlocked=1; break; }
    done
    wait "$pid" 2>/dev/null || true
  done
  cw1="$(date +%s%N 2>/dev/null)"; case "$cw1" in *[!0-9]*|'') cw1=0;; esac
  cwall=0; [ "$cw1" -gt "$cw0" ] 2>/dev/null && cwall=$(( (cw1 - cw0) / 1000000 ))
  completed=0; ok=0; i=0
  while [ "$i" -lt "$P" ]; do
    i=$((i+1)); rf="$WORK/s2r$i"
    [ -s "$rf" ] && completed=$((completed+1))
    grep -q '^OK' "$rf" 2>/dev/null && ok=$((ok+1))
  done
  fd_after="$(ls /proc/$$/fd 2>/dev/null | wc -l | tr -d ' ')"; fd_after="${fd_after:-0}"
  fd_delta=$(( fd_after - fd_before ))
  { echo "=== (S2) concurrent auth (mode=$MODE) ===";
    echo "parallelism P        : $P (>=10 required)";
    echo "workers completed     : $completed";
    echo "workers OK            : $ok";
    echo "deadlocked (>60s hang): $deadlocked (want 0)";
    echo "wall (all workers)    : ${cwall} ms";
    echo "parent fd before/after: $fd_before / $fd_after (delta=$fd_delta; want small, no leak)";
    echo "per-worker results:"; for i in $(seq 1 "$P"); do echo "  w$i: $(cat "$WORK/s2r$i" 2>/dev/null || echo '<none>')"; done; } > "$ev"
  # no deadlock, every worker completed + OK, fd count did not balloon
  if [ "$deadlocked" = 0 ] && [ "$completed" = "$P" ] && [ "$ok" = "$P" ] && [ "$fd_delta" -le 8 ]; then
    ab_pass_with_evidence "S2 concurrent: $ok/$P parallel workers OK, no deadlock, fd_delta=$fd_delta (no leak)" "$ev"
  else
    ab_fail "S2 concurrent: ok=$ok/$P completed=$completed deadlock=$deadlocked fd_delta=$fd_delta [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# CHAOS — all require the LIVE auth-pivot stack. SKIP cleanly when it is down.
# =========================================================================
CHAOS_LIVE="${HC_CHAOS_LIVE:-1}"
_chaos_stack_probe="${HC_NEW_STACK_DETAIL:-<not-probed>}"

# helper: emit a stack-down SKIP with evidence for a chaos scenario
_chaos_skip_down() { # <slug> <human>
  local ev; ev="$(h_ev "$1")"
  { echo "chaos [$2] requires the LIVE auth-pivot ssh-key stack (conductor deploys it later)";
    echo "probe: $_chaos_stack_probe"; } > "$ev"
  ab_skip_with_reason "$2: auth-pivot stack not deployed" topology_unsupported
}

# =========================================================================
# (C4) FD / connection PRESSURE — clean refuse/queue, edge reachable after.
# =========================================================================
h_head "(C4) fd/connection pressure -> edge survives (no crash), reachable after"
if [ "$STACK_UP" != 1 ]; then
  _chaos_skip_down c4_pressure "C4 fd/connection pressure"
else
  ev="$(h_ev c4_pressure)"; raw="$(h_ev c4_raw)"
  PN="${HC_CHAOS_PRESSURE_N:-150}"; PC="${HC_CHAOS_PRESSURE_C:-60}"
  case "$PN" in ''|*[!0-9]*) PN=150;; esac; case "$PC" in ''|*[!0-9]*) PC=60;; esac
  [ "$PN" -gt 1000 ] && PN=1000; [ "$PC" -gt 128 ] && PC=128; [ "$PC" -lt 1 ] && PC=1
  : > "$raw"
  seq 1 "$PN" | xargs -P "$PC" -I{} \
    curl -k -s -o /dev/null -w '%{http_code}\n' --max-time 15 "$HC_BASE/login" >> "$raw" 2>/dev/null
  completed="$(wc -l < "$raw" | tr -d ' ')"
  okc="$(awk '$1==200||$1==302||$1==303||$1==401{c++} END{print c+0}' "$raw")"
  refused="$(awk '$1==000{c++} END{print c+0}' "$raw")"
  post="$(hc_http_code "$HC_BASE/")"; gate_post="$(hc_http_code "http://${HC_GATE_ADDR}/healthz")"
  { echo "=== (C4) fd/connection pressure (bounded §12.6) ===";
    echo "pressure: N=$PN C=$PC";
    echo "completed=$completed answered(200/302/303/401)=$okc refused/timeout(000)=$refused";
    echo "post edge GET / = $post (000 = edge down) ; post gate /healthz = $gate_post";
    echo "code distribution:"; sort "$raw" | uniq -c; } > "$ev"
  if [ "$post" != 000 ] && [ "$okc" -gt 0 ]; then
    ab_pass_with_evidence "C4 pressure: edge survived $PN conns @C=$PC (answered=$okc refused=$refused), reachable after (GET / -> $post)" "$ev"
  else
    ab_fail "C4 pressure: edge did not survive (post=$post answered=$okc) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# (C1) KILL GATE mid-session -> Caddy FAIL-CLOSED (never bypass) -> recover.
# =========================================================================
h_head "(C1) kill helix-auth gate -> Caddy denies (fail-closed) -> restart -> recover"
if [ "$STACK_UP" != 1 ]; then
  _chaos_skip_down c1_gate_kill "C1 kill gate + fail-closed"
elif [ "$CHAOS_LIVE" != 1 ]; then
  ev="$(h_ev c1_gate_kill)"; { echo "HC_CHAOS_LIVE!=1 — destructive gate kill skipped (dry run)"; } > "$ev"
  ab_skip_with_reason "C1 kill gate skipped in dry-run (HC_CHAOS_LIVE=0)" feature_disabled_by_config
else
  ev="$(h_ev c1_gate_kill)"
  gpid="$(_pid_on_port "$HC_GATE_ADDR")"
  { echo "=== (C1) kill gate -> fail-closed -> recover ===";
    echo "gate addr=$HC_GATE_ADDR pid=${gpid:-<none>}"; } > "$ev"
  if ! _pid_owned "$gpid" 'helix-auth|auth_gate'; then
    echo "gate PID not positively OURS (UID+argv) — refusing to kill (§11.4.174)" >> "$ev"
    ab_skip_with_reason "C1 kill gate: gate process not positively ours ($HC_GATE_ADDR)" topology_unsupported
  else
    pre_edge="$(hc_http_code "$HC_BASE/")"
    _NEED_GATE_RECOVER=1
    kill -9 "$gpid" 2>/dev/null || true
    echo "action=SIGKILL gate pid=$gpid at $(date -u +%H:%M:%SZ)" >> "$ev"
    # --- OBSERVE: while the forward_auth target is down, the edge MUST deny ---
    during_edge=""; bypass=0; edge_answered=0
    for i in 1 2 3 4 5 6 7 8; do
      c="$(hc_http_code "$HC_BASE/")"; echo "during_edge_$i=$c" >> "$ev"
      [ "$c" != 000 ] && edge_answered=1
      case "$c" in 200) bypass=1; during_edge=200; break;; 401|403|500|502|503) during_edge="$c"; break;; esac
      [ "$i" -ge 2 ] && sleep 1
    done
    gate_down="$(hc_http_code "http://${HC_GATE_ADDR}/auth")"
    echo "during gate /auth = $gate_down (expect 000/refused while gate down)" >> "$ev"
    # --- RECOVER ---
    recovered_by="auto(restart-policy)"; _gate_recover >/dev/null 2>&1 || true
    _gate_healthy || recovered_by="manual(systemctl --user)"
    _NEED_GATE_RECOVER=0
    gate_post="$(hc_http_code "http://${HC_GATE_ADDR}/healthz")"
    post_edge="$(hc_http_code "$HC_BASE/")"
    { echo "bypass_during_gate_down=$bypass (want 0 — a 200 editor serve = FAIL-OPEN)";
      echo "edge_answered_a_denial=$edge_answered during_edge=${during_edge:-<none>} (401/403/5xx = fail-closed deny)";
      echo "recovered_by=$recovered_by gate /healthz=$gate_post post edge GET /=$post_edge"; } >> "$ev"
    # PASS: never bypassed (no 200) AND edge answered a denial AND gate recovered AND edge challenges again
    if [ "$bypass" = 0 ] && [ "$edge_answered" = 1 ] && [ "$gate_post" = 200 ] && [ "$post_edge" != 000 ]; then
      ab_pass_with_evidence "C1: gate down -> edge denied (during=$during_edge, no bypass), gate recovered (healthz=$gate_post) via $recovered_by" "$ev"
    else
      ab_fail "C1: bypass=$bypass edge_answered=$edge_answered gate_recovered=$gate_post post_edge=$post_edge (want 0/1/200/!=000) [ev: ${ev#$HC_ROOT/}]"
    fi
  fi
fi

# =========================================================================
# (C2) KILL code-server -> edge+gate stay up -> code-server recovers.
# =========================================================================
h_head "(C2) kill code-server -> edge/gate stay up -> code-server recovers"
if [ "$STACK_UP" != 1 ]; then
  _chaos_skip_down c2_cs_kill "C2 kill code-server"
elif [ "$CHAOS_LIVE" != 1 ]; then
  ev="$(h_ev c2_cs_kill)"; { echo "HC_CHAOS_LIVE!=1 — destructive code-server kill skipped (dry run)"; } > "$ev"
  ab_skip_with_reason "C2 kill code-server skipped in dry-run (HC_CHAOS_LIVE=0)" feature_disabled_by_config
else
  ev="$(h_ev c2_cs_kill)"
  cspid="$(_pid_on_port "$HC_CSVR_ADDR")"
  { echo "=== (C2) kill code-server -> recover ===";
    echo "code-server addr=$HC_CSVR_ADDR pid=${cspid:-<none>}"; } > "$ev"
  killed=0; via=""
  if _pid_owned "$cspid" 'code-server|code_server|node'; then
    _NEED_CS_RECOVER=1; kill -9 "$cspid" 2>/dev/null && killed=1; via="host-native pid $cspid"
  elif "$HC_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$HC_CS"; then
    _NEED_CS_RECOVER=1; "$HC_ENGINE" kill "$HC_CS" >/dev/null 2>&1 && killed=1; via="container $HC_CS"
  fi
  if [ "$killed" != 1 ]; then
    echo "code-server not positively ours (no owned host pid, no $HC_CS container) — refusing to kill" >> "$ev"
    ab_skip_with_reason "C2 kill code-server: process not positively ours ($HC_CSVR_ADDR / $HC_CS)" topology_unsupported
  else
    echo "action=KILL code-server via $via at $(date -u +%H:%M:%SZ)" >> "$ev"
    down=0
    for i in 1 2 3 4 5; do c="$(hc_http_code "http://${HC_CSVR_ADDR}/")"; echo "during_cs_$i=$c" >> "$ev"; [ "$c" = 000 ] && { down=1; break; }; sleep 1; done
    # edge + gate must remain up (gate still denies unauth) while code-server is down
    edge_up="$(hc_http_code "$HC_BASE/")"; gate_up="$(hc_http_code "http://${HC_GATE_ADDR}/healthz")"
    echo "during edge GET /=$edge_up (want != 000, still answering) gate /healthz=$gate_up" >> "$ev"
    recovered_by="auto(restart-policy)"; _cs_recover >/dev/null 2>&1 || true
    _cs_up || recovered_by="manual(systemctl/container)"
    _NEED_CS_RECOVER=0
    post="$(hc_http_code "http://${HC_CSVR_ADDR}/")"
    { echo "cs_went_down=$down (want 1 — the kill took effect)";
      echo "edge_stayed_up=$([ "$edge_up" != 000 ] && echo yes || echo no) gate_stayed_up=$([ "$gate_up" = 200 ] && echo yes || echo no)";
      echo "recovered_by=$recovered_by post code-server GET /=$post (want != 000)"; } >> "$ev"
    if [ "$down" = 1 ] && [ "$edge_up" != 000 ] && [ "$post" != 000 ]; then
      ab_pass_with_evidence "C2: code-server killed ($via) went down, edge stayed up, code-server recovered ($post) via $recovered_by" "$ev"
    else
      ab_fail "C2: down=$down edge_up=$edge_up post=$post (want 1/!=000/!=000) [ev: ${ev#$HC_ROOT/}]"
    fi
  fi
fi

# =========================================================================
# (C3) CORRUPT the cookie secret -> a previously-valid session is INVALIDATED.
# =========================================================================
h_head "(C3) corrupt cookie secret -> existing session invalidated (NOT bypassed)"
SECRET_FILE="${HELIX_AUTH_COOKIE_SECRET_FILE:-}"
KEYFILE="${HELIX_TEST_SSH_KEY:-}"
# C3 proves: rotating the cookie-signing secret INVALIDATES an already-issued
# session (the gate loads the secret at startup, so old HMAC cookies fail after a
# reload). DEFAULT path = an ISOLATED throwaway gate — autonomous, non-destructive,
# needs NO real credential (it trusts only its own throwaway key). The LEGACY path
# rotates the LIVE gate's secret and is DESTRUCTIVE (it logs the operator's live
# session out), so it runs ONLY on an explicit opt-in (§11.4.101): HC_CHAOS_LIVE=1
# + a writable HELIX_AUTH_COOKIE_SECRET_FILE + an authorized HELIX_TEST_SSH_KEY on
# the live stack.
if [ "$STACK_UP" = 1 ] && [ "$CHAOS_LIVE" = 1 ] \
   && [ -n "$SECRET_FILE" ] && [ -f "$SECRET_FILE" ] && [ -w "$SECRET_FILE" ] \
   && [ -n "$KEYFILE" ] && [ -r "$KEYFILE" ] && h_require ssh-keygen; then
  ev="$(h_ev c3_secret)"; JAR="$WORK/c3jar"
  _SECRET_LIVE="$SECRET_FILE"; _SECRET_BAK="$WORK/secret.bak"
  cp -f "$SECRET_FILE" "$_SECRET_BAK" 2>/dev/null || true
  { echo "=== (C3) corrupt cookie secret -> invalidate existing session (LIVE gate, opt-in) ===";
    echo "secret file (path only, contents never printed §11.4.10): $SECRET_FILE"; } > "$ev"
  if hc_sshkey_login "$HC_BASE" "$KEYFILE" "$JAR" "$PRINCIPAL"; then
    pre_auth="$(curl -k -s -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 "http://${HC_GATE_ADDR}/auth" 2>/dev/null || echo 000)"
    echo "session minted (POST /login=$HC_SSHKEY_CODE); pre-rotation gate /auth with cookie = $pre_auth (want 200)" >> "$ev"
    # --- INJECT: rotate the secret to fresh random bytes, reload the gate ---
    head -c 48 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' > "$SECRET_FILE" 2>/dev/null || date +%s%N > "$SECRET_FILE"
    _gate_recover >/dev/null 2>&1 || true
    echo "action=rotated cookie secret + reloaded gate at $(date -u +%H:%M:%SZ)" >> "$ev"
    post_auth="$(curl -k -s -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 "http://${HC_GATE_ADDR}/auth" 2>/dev/null || echo 000)"
    echo "post-rotation gate /auth with the SAME old cookie = $post_auth (want 401 — invalidated, NOT 200 bypass)" >> "$ev"
    # --- RESTORE ---
    cp -f "$_SECRET_BAK" "$SECRET_FILE" 2>/dev/null || true; _gate_recover >/dev/null 2>&1 || true
    _SECRET_BAK=""; _SECRET_LIVE=""
    gate_final="$(hc_http_code "http://${HC_GATE_ADDR}/healthz")"
    echo "restored original secret + reloaded gate; final gate /healthz = $gate_final" >> "$ev"
    if [ "$pre_auth" = 200 ] && [ "$post_auth" = 401 ] && [ "$gate_final" = 200 ]; then
      ab_pass_with_evidence "C3 (live gate): valid session (pre=200) INVALIDATED after secret rotation (post=401, not bypassed); gate restored ($gate_final)" "$ev"
    else
      ab_fail "C3: pre_auth=$pre_auth post_auth=$post_auth gate_final=$gate_final (want 200/401/200) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    cp -f "$_SECRET_BAK" "$SECRET_FILE" 2>/dev/null || true; _SECRET_BAK=""; _SECRET_LIVE=""
    { echo "could not mint a real session with the provided key (POST /login=$HC_SSHKEY_CODE)"; } >> "$ev"
    ab_fail "C3: could not mint a real session to test secret invalidation (code=$HC_SSHKEY_CODE) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  # DEFAULT autonomous path: isolated throwaway gate (non-destructive, no credential).
  ev="$(h_ev c3_secret)"
  _tg_rc=2
  if command -v go >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    hc_spawn_throwaway_gate "$WORK" "milosvasic"; _tg_rc=$?
  fi
  if [ "$_tg_rc" = 0 ]; then
    _TG_ACTIVE=1; JAR="$WORK/c3jar_tg"; : > "$JAR"
    { echo "=== (C3) corrupt cookie secret -> invalidate existing session (ISOLATED throwaway gate) ===";
      echo "isolated gate (own loopback port, NON-destructive to the live gate): $HC_TG_BASE";
      echo "throwaway cookie-secret (path only, contents never printed §11.4.10): $HC_TG_SECRET"; } > "$ev"
    if hc_sshkey_login "$HC_TG_BASE" "$HC_TG_KEY" "$JAR" "$HC_TG_PRINCIPAL"; then
      pre_auth="$(curl -s -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$HC_TG_BASE/auth" 2>/dev/null || echo 000)"
      echo "session minted (POST /login=$HC_SSHKEY_CODE); pre-rotation /auth with cookie = $pre_auth (want 200)" >> "$ev"
      head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' > "$HC_TG_SECRET" 2>/dev/null || date +%s%N > "$HC_TG_SECRET"
      # metamorphic anti-bluff control (§11.4.107 causality): rotating the file
      # WITHOUT a reload must NOT invalidate (secret still in memory) -> proves the
      # post-reload 401 is caused by the reload, not cookie expiry or a flat-401 gate.
      norestart_auth="$(curl -s -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$HC_TG_BASE/auth" 2>/dev/null || echo 000)"
      echo "control: rotate WITHOUT reload -> /auth = $norestart_auth (want 200 — invalidation MUST require the reload)" >> "$ev"
      hc_restart_throwaway_gate >/dev/null 2>&1 || true
      post_auth="$(curl -s -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$HC_TG_BASE/auth" 2>/dev/null || echo 000)"
      echo "post-reload /auth with the SAME old cookie = $post_auth (want 401 — invalidated, NOT 200 bypass)" >> "$ev"
      healthz="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HC_TG_BASE/healthz" 2>/dev/null || echo 000)"
      echo "isolated gate final /healthz = $healthz (want 200 — gate survived rotate+reload)" >> "$ev"
      hc_stop_throwaway_gate; _TG_ACTIVE=0
      if [ "$pre_auth" = 200 ] && [ "$norestart_auth" = 200 ] && [ "$post_auth" = 401 ] && [ "$healthz" = 200 ]; then
        ab_pass_with_evidence "C3 (isolated gate): session (pre=200) INVALIDATED after secret rotation+reload (post=401); rotate-without-reload control=200 proves causality; gate healthy — non-destructive, no real credential" "$ev"
      else
        ab_fail "C3 (isolated gate): pre=$pre_auth norestart=$norestart_auth post=$post_auth healthz=$healthz (want 200/200/401/200) [ev: ${ev#$HC_ROOT/}]"
      fi
    else
      hc_stop_throwaway_gate; _TG_ACTIVE=0
      { echo "could not mint a session against the isolated throwaway gate (POST /login=$HC_SSHKEY_CODE)"; } >> "$ev"
      ab_fail "C3 (isolated gate): could not mint a session (code=$HC_SSHKEY_CODE) [ev: ${ev#$HC_ROOT/}]"
    fi
  elif [ "$_tg_rc" = 1 ]; then
    # go + ssh-keygen ARE present but building/launching the isolated gate FAILED
    # (compile break / launch fault) — a REAL defect, NOT a topology gap. FAIL, never
    # mask a gate-build breakage as a SKIP (§11.4.1 / §11.4.6 honesty).
    hc_stop_throwaway_gate 2>/dev/null || true
    { echo "isolated-gate C3: helix-auth build/launch FAILED (rc=1) with go+ssh-keygen present";
      echo "— a real defect (compile break / launch fault), NOT a topology gap"; } > "$ev"
    ab_fail "C3 (isolated gate): helix-auth build/launch failed (rc=1) with go present — real defect, not a topology SKIP [ev: ${ev#$HC_ROOT/}]"
  else
    # _tg_rc=2: go or ssh-keygen genuinely ABSENT -> cannot build an isolated gate,
    # and the destructive live-gate rotation is opt-in only -> neither path available.
    hc_stop_throwaway_gate 2>/dev/null || true
    { echo "isolated-gate C3 needs the go toolchain to build helix-auth AND ssh-keygen (rc=$_tg_rc);";
      echo "the LIVE-gate rotation is destructive and opt-in only (HC_CHAOS_LIVE=1 + writable";
      echo "HELIX_AUTH_COOKIE_SECRET_FILE + authorized HELIX_TEST_SSH_KEY), so neither path is available."; } > "$ev"
    ab_skip_with_reason "C3 corrupt cookie secret: go/ssh-keygen absent to build an isolated gate; destructive live-gate rotation not opted-in" topology_unsupported
  fi
fi

h_summary
