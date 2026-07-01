#!/usr/bin/env bash
#
# tests/types/concurrency_auth.sh — CONCURRENCY / ATOMICITY correctness suite
# (§11.4.85 / §11.4.169) for the 2026-07-01 SSH-KEY auth gate
# (docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md).
#
# Where stress_chaos_auth.sh proves resilience under LOAD, this suite proves the
# gate's session semantics stay CORRECT under CONCURRENCY:
#
#   (K1) SELF-CONTAINED identity isolation (always runs, no stack) — >=10 parallel
#        workers each with a DIFFERENT key sign the SAME nonce; each signature
#        verifies against its OWN allowed_signers (ACCEPT) and is REJECTED against a
#        DIFFERENT worker's — proves independent identities never cross-authorize
#        under concurrency, and every worker completes (no deadlock). This is the
#        gate's REAL verify primitive (`ssh-keygen -Y verify`), not a mock (§11.4.27).
#   (K2) CONCURRENT INDEPENDENT SESSIONS — >=10 parallel valid logins each issue a
#        DISTINCT session cookie, and every issued cookie independently authorizes.
#   (K3) ATOMIC COOKIE ISSUANCE — every concurrent login that succeeds carries a
#        COMPLETE, working session cookie (no torn/partial cookie: successes == the
#        number of cookies that actually authorize).
#   (K4) REPLAY-GUARD EXACTLY-ONCE under concurrency — one challenge is signed once,
#        then POSTed from >=10 parallel requests; EXACTLY ONE succeeds (302/303 +
#        cookie), the rest are denied (the nonce is single-use, no double-spend).
#   (K5) NO SESSION FIXATION — the session identifier issued on login DIFFERS from
#        any cookie the server handed out pre-authentication (id changes on login).
#   (K6) NO DEADLOCK — every concurrent operation completes within a bounded window.
#
# TARGET resolution (§11.4.6 no guessing): the LIVE edge (HC_BASE) if the full
# stack is up, else the gate directly (http://HC_GATE_ADDR) if it answers /healthz,
# else a locally-run gate binary if one is present ($HELIX_AUTH_BIN or
# ~/.local/bin/helix-auth) AND it comes up (a self-launched gate authorizes a key WE
# generate -> fully autonomous per §11.4.98); a mis-guessed launch env simply fails
# the /healthz probe -> SKIP, NEVER a false PASS. We NEVER build from
# services/auth_gate (another stream owns it). When no target and/or no authorized
# key is available, the stack-dependent assertions SKIP-with-reason — never faked
# (§11.4/§11.4.1/§11.4.69). No secret/cookie VALUE is ever written to evidence
# (only sha256 fingerprints are compared) (§11.4.10).
#
# §1.1 PAIRED-MUTATION intent:
#   (K1) let a signature verify against a different key -> isolation FAILs.
#   (K2) make the gate reuse one session id for all logins -> not-distinct -> FAILs.
#   (K3) issue a 302 with an empty/partial cookie -> successes != authorized -> FAILs.
#   (K4) drop the single-use nonce check -> >1 replay succeeds -> FAILs.
#   (K5) keep the pre-login cookie as the session -> fingerprint unchanged -> FAILs.
#
# Usage:        bash tests/types/concurrency_auth.sh
# Inputs:       deploy/.env + HELIX_AUTH_ADDR (via fixture) ; HC_CONC (>=10) ;
#               HELIX_TEST_SSH_KEY (authorized key) HELIX_AUTH_PRINCIPAL ;
#               HELIX_AUTH_BIN / ~/.local/bin/helix-auth (optional local gate)
# Outputs:      qa-results/tests/concurrency_auth/<run-id>/*.txt ; exit 0 iff all PASS/SKIP
# Side-effects: parallel GET/POST /login probes; throwaway keys/jars + any launched
#               local gate are trap-cleaned; never mutates the shared stack or git
# Dependencies: bash, ssh-keygen ; curl (live steps) ; coreutils, awk ; sha256sum|shasum
# Cross-refs:   §11.4.6 §11.4.10 §11.4.69 §11.4.85 §11.4.98 §11.4.107 §11.4.169 ;
#               harness.sh stack_fixture.sh ; specs 2026-07-01-auth-pivot-ssh-key.md
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"
# shellcheck source=../lib/stack_fixture.sh
. "$_here/../lib/stack_fixture.sh"

h_init concurrency_auth

PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_conc_auth.XXXXXX")"
P="${HC_CONC:-12}"; case "$P" in ''|*[!0-9]*) P=12;; esac
[ "$P" -lt 10 ] && P=10; [ "$P" -gt 64 ] && P=64

LG_PID=""   # locally-launched gate, killed by the trap if we started one
cleanup() {
  [ -n "$LG_PID" ] && kill "$LG_PID" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# ---- helpers -------------------------------------------------------------
_hash() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
          elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
          else cksum | awk '{print $1"-"$2}'; fi; }
# cookie VALUE column of a Netscape jar (col 7; handles curl's #HttpOnly_ prefix).
# Values are session tokens -> only their sha256 fingerprint is ever emitted.
_jar_values() { awk '/^#HttpOnly_/{print $7; next} /^#/{next} NF{print $7}' "${1:-/dev/null}" 2>/dev/null; }
_jar_fp() { _jar_values "$1" | sort | _hash; }
_code_jar() { curl -k -s -b "$2" -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || echo 000; }

# ssh-keygen crypto ops with bounded retry (§11.4.50 determinism). FACT (captured):
# `ssh-keygen -Y sign`/keygen errors transiently under a concurrent fork storm
# (~1 worker in ~40% of 12-way rounds); ZERO verify-mismatches ever — the crypto
# never false-accepts. A concurrency test must not itself flake (§11.4.1 FAIL-bluff):
# must-SUCCEED ops (keygen/sign/verify-correct) retry 3x; the must-FAIL op (reject a
# FOREIGN key's signature) is SINGLE-attempt so a real cross-accept is NEVER masked.
_kg3()   { local i; for i in 1 2 3; do rm -f "$1" "$1.pub" 2>/dev/null; ssh-keygen -q -t ed25519 -N '' -C "${2:-hc}" -f "$1" </dev/null >/dev/null 2>&1 && return 0; done; return 1; }
_sign3() { local i; for i in 1 2 3; do printf %s "$1" | ssh-keygen -Y sign -n "$HC_SIGN_NAMESPACE" -f "$2" > "$3" 2>/dev/null && grep -q 'BEGIN SSH SIGNATURE' "$3" && return 0; done; return 1; }
_vok3()  { local i; for i in 1 2 3; do printf %s "$1" | ssh-keygen -Y verify -f "$2" -I "$PRINCIPAL" -n "$HC_SIGN_NAMESPACE" -s "$3" >/dev/null 2>&1 && return 0; done; return 1; }
_vreject(){ ! printf %s "$1" | ssh-keygen -Y verify -f "$2" -I "$PRINCIPAL" -n "$HC_SIGN_NAMESPACE" -s "$3" >/dev/null 2>&1; }
_login3(){ local i; for i in 1 2 3; do hc_sshkey_login "$1" "$2" "$3" "$4" && return 0; done; return 1; }

# _launch_local_gate: best-effort self-contained gate (spec-documented params only).
# Sets LG_BASE / LG_KEY / LG_PID on success. A wrong/unknown listen-env just means
# the /healthz probe never turns 200 -> return 1 -> caller SKIPs (no false PASS).
_launch_local_gate() {
  LG_BASE=""; LG_KEY=""; LG_PID=""
  h_require ssh-keygen || return 1
  local bin; bin="${HELIX_AUTH_BIN:-$HOME/.local/bin/helix-auth}"
  [ -x "$bin" ] || return 1
  local d ak port i; d="$WORK/lg"; mkdir -p "$d"
  ssh-keygen -q -t ed25519 -N '' -C 'helixcode-lg' -f "$d/id" </dev/null >/dev/null 2>&1 || return 1
  ak="$d/authorized_keys"; cp "$d/id.pub" "$ak"
  port="${HELIX_AUTH_LOCAL_PORT:-18081}"
  HELIX_AUTH_MODE=sshkey HELIX_AUTH_ACCOUNT="$PRINCIPAL" HELIX_AUTH_PRINCIPAL="$PRINCIPAL" \
    HELIX_AUTH_AUTHORIZED_KEYS="$ak" HELIX_AUTH_ADDR="127.0.0.1:$port" \
    HELIX_AUTH_LISTEN="127.0.0.1:$port" HELIX_AUTH_PORT="$port" \
    "$bin" >"$d/gate.log" 2>&1 &
  LG_PID=$!
  for i in $(seq 1 16); do
    kill -0 "$LG_PID" 2>/dev/null || { LG_PID=""; return 1; }
    [ "$(hc_http_code "http://127.0.0.1:$port/healthz")" = 200 ] && { LG_BASE="http://127.0.0.1:$port"; LG_KEY="$d/id"; return 0; }
    sleep 1
  done
  kill "$LG_PID" 2>/dev/null || true; LG_PID=""; return 1
}

# resolve target base + a valid-login key + authorize-check mode
TARGET=""; TKEY=""; TMODE=""
if hc_new_stack_up; then
  TARGET="$HC_BASE"; TMODE="edge"; TKEY="${HELIX_TEST_SSH_KEY:-}"
elif [ "$(hc_http_code "http://${HC_GATE_ADDR}/healthz")" = 200 ]; then
  TARGET="http://${HC_GATE_ADDR}"; TMODE="gate-direct"; TKEY="${HELIX_TEST_SSH_KEY:-}"
elif _launch_local_gate; then
  TARGET="$LG_BASE"; TMODE="local-launched"; TKEY="$LG_KEY"
fi
# authorized-session check URL per mode (edge: authed GET / = 200; gate: /auth = 200)
_authz_code() { case "$TMODE" in edge) _code_jar "$HC_BASE/" "$1";; *) _code_jar "$TARGET/auth" "$1";; esac; }

# =========================================================================
# (K1) SELF-CONTAINED identity isolation under concurrency (no stack).
# =========================================================================
h_head "(K1) parallel identity isolation: each key verifies only as itself (no cross-auth)"
ev="$(h_ev k1_isolation)"
if ! h_require ssh-keygen; then
  { echo "ssh-keygen not on PATH — cannot exercise the verify primitive"; } > "$ev"
  ab_skip_with_reason "K1 identity isolation: ssh-keygen not on PATH" topology_unsupported
else
  NONCE="k1-shared-$RANDOM$RANDOM-$$"
  _k1_worker() { # <id> — sign the shared nonce with this worker's own key (retry-hardened)
    local id="$1" d="$WORK/k1w$1"
    mkdir -p "$d"
    _kg3 "$d/k" "k1-$id" || { echo FAIL-keygen > "$d/st"; return; }
    printf '%s %s\n' "$PRINCIPAL" "$(cat "$d/k.pub")" > "$d/as"
    _sign3 "$NONCE" "$d/k" "$d/sig" || { echo FAIL-sign > "$d/st"; return; }
    echo OK > "$d/st"
  }
  cw0="$(date +%s%N 2>/dev/null)"; case "$cw0" in *[!0-9]*|'') cw0=0;; esac
  pids=""; i=0; while [ "$i" -lt "$P" ]; do i=$((i+1)); _k1_worker "$i" & pids="$pids $!"; done
  deadlocked=0
  for pid in $pids; do w=0; while kill -0 "$pid" 2>/dev/null; do sleep 1; w=$((w+1)); [ "$w" -ge 60 ] && { kill "$pid" 2>/dev/null||true; deadlocked=1; break; }; done; wait "$pid" 2>/dev/null||true; done
  cw1="$(date +%s%N 2>/dev/null)"; case "$cw1" in *[!0-9]*|'') cw1=0;; esac
  cwall=0; [ "$cw1" -gt "$cw0" ] 2>/dev/null && cwall=$(( (cw1 - cw0) / 1000000 ))
  signed=0; self_ok=0; cross_reject=0; checks=0; i=0
  while [ "$i" -lt "$P" ]; do
    i=$((i+1)); d="$WORK/k1w$i"
    [ "$(cat "$d/st" 2>/dev/null)" = OK ] || continue
    signed=$((signed+1))
    # this key's signature must ACCEPT against its own signers (must-succeed -> retry)
    if _vok3 "$NONCE" "$d/as" "$d/sig"; then self_ok=$((self_ok+1)); fi
    # ...and be REJECTED against a DIFFERENT worker's signers (must-fail -> single attempt)
    o=$(( (i % P) + 1 )); [ "$o" = "$i" ] && o=$(( (i % P) + 2 )); [ "$o" -gt "$P" ] && o=1
    if [ -s "$WORK/k1w$o/as" ]; then
      checks=$((checks+1))
      _vreject "$NONCE" "$WORK/k1w$o/as" "$d/sig" && cross_reject=$((cross_reject+1))
    fi
  done
  { echo "=== (K1) parallel identity isolation (self-contained) ===";
    echo "parallelism P=$P shared nonce (one nonce, P distinct keys)";
    echo "workers signed OK          : $signed (want $P)";
    echo "self-verify ACCEPTED        : $self_ok (want $signed)";
    echo "cross-key checks / rejected : $checks / $cross_reject (want rejected == checks)";
    echo "deadlocked (>60s)           : $deadlocked (want 0)";
    echo "wall                        : ${cwall} ms"; } > "$ev"
  if [ "$deadlocked" = 0 ] && [ "$signed" = "$P" ] && [ "$self_ok" = "$P" ] && [ "$checks" -ge 1 ] && [ "$cross_reject" = "$checks" ]; then
    ab_pass_with_evidence "K1: $P parallel identities each verify as themselves, all cross-key checks rejected ($cross_reject/$checks), no deadlock" "$ev"
  else
    ab_fail "K1: signed=$signed self_ok=$self_ok cross_reject=$cross_reject/$checks deadlock=$deadlocked (want all-isolated) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# Gate-dependent assertions (K2..K6): need a target + an authorized key.
# =========================================================================
if [ -z "$TARGET" ]; then
  ev="$(h_ev target_down)"
  { echo "no ssh-key auth target: live edge/gate down AND no launchable local gate";
    echo "probe: ${HC_NEW_STACK_DETAIL:-<none>} ; HELIX_AUTH_BIN=${HELIX_AUTH_BIN:-<unset>}"; } > "$ev"
  ab_skip_with_reason "concurrency K2-K6: no ssh-key auth target deployed/launchable" topology_unsupported
  h_summary; exit $?
fi
if [ -z "$TKEY" ] || [ ! -r "$TKEY" ] || ! h_require ssh-keygen; then
  ev="$(h_ev key_absent)"
  { echo "target=$TARGET (mode=$TMODE) reachable, but no authorized key to mint real sessions";
    echo "K2-K6 require a valid login (HELIX_TEST_SSH_KEY for the live stack; a self-launched";
    echo "gate authorizes a key we generate). A mock session is forbidden (§11.4.27) -> SKIP."; } > "$ev"
  ab_skip_with_reason "concurrency K2-K6: no authorized key to mint real sessions (HELIX_TEST_SSH_KEY)" credential_absent
  h_summary; exit $?
fi

# =========================================================================
# (K2) CONCURRENT INDEPENDENT SESSIONS  +  (K3) ATOMIC COOKIE ISSUANCE.
# =========================================================================
h_head "(K2/K3) >=10 parallel logins -> distinct sessions, each cookie complete+working"
ev="$(h_ev k2_sessions)"
_login_worker() { # <id> — full independent login into its own jar
  local id="$1" jar="$WORK/k2j$1" st="$WORK/k2s$1"
  if _login3 "$TARGET" "$TKEY" "$jar" "$PRINCIPAL"; then
    local az; az="$(_authz_code "$jar")"
    printf 'OK code=%s newcookie=%s authz=%s\n' "$HC_SSHKEY_CODE" "${HC_SSHKEY_NEWCOOKIE:-none}" "$az" > "$st"
  else
    printf 'FAIL code=%s\n' "$HC_SSHKEY_CODE" > "$st"
  fi
}
cw0="$(date +%s%N 2>/dev/null)"; case "$cw0" in *[!0-9]*|'') cw0=0;; esac
pids=""; i=0; while [ "$i" -lt "$P" ]; do i=$((i+1)); _login_worker "$i" & pids="$pids $!"; done
deadlocked=0
for pid in $pids; do w=0; while kill -0 "$pid" 2>/dev/null; do sleep 1; w=$((w+1)); [ "$w" -ge 90 ] && { kill "$pid" 2>/dev/null||true; deadlocked=1; break; }; done; wait "$pid" 2>/dev/null||true; done
cw1="$(date +%s%N 2>/dev/null)"; case "$cw1" in *[!0-9]*|'') cw1=0;; esac
k2wall=0; [ "$cw1" -gt "$cw0" ] 2>/dev/null && k2wall=$(( (cw1 - cw0) / 1000000 ))
success=0; authorized=0; i=0; : > "$WORK/k2fps"
while [ "$i" -lt "$P" ]; do
  i=$((i+1)); st="$WORK/k2s$i"; jar="$WORK/k2j$i"
  grep -q '^OK' "$st" 2>/dev/null || continue
  success=$((success+1))
  # An authorized session ROUTES THROUGH the gate: the edge GET / then reaches
  # code-server (302 redirect / 200), and the gate's /auth returns 200. The
  # fail-closed UNAUTH signal is 401 — so authz in {200,302,303} is positive
  # proof the cookie authorized (a no-cookie control returns 401, never 302).
  grep -Eq 'authz=(200|302|303)' "$st" 2>/dev/null && authorized=$((authorized+1))
  [ -s "$jar" ] && _jar_fp "$jar" >> "$WORK/k2fps"   # fingerprint only (§11.4.10)
done
distinct="$(sort -u "$WORK/k2fps" 2>/dev/null | grep -c . || echo 0)"
{ echo "=== (K2/K3) concurrent independent sessions + atomic cookie ===";
  echo "parallelism P=$P mode=$TMODE";
  echo "logins succeeded (302/303 + new cookie): $success (want $P)";
  echo "distinct session fingerprints           : $distinct (want == successes -> independent sessions)";
  echo "sessions that authorize (authz in 200/302/303, routed not 401): $authorized (want == successes -> atomic, complete cookie)";
  echo "deadlocked (>90s)                        : $deadlocked (want 0)";
  echo "wall                                     : ${k2wall} ms";
  echo "per-worker:"; for i in $(seq 1 "$P"); do echo "  w$i: $(cat "$WORK/k2s$i" 2>/dev/null || echo '<none>')"; done; } > "$ev"
# K2 assertion
if [ "$deadlocked" = 0 ] && [ "$success" = "$P" ] && [ "$distinct" = "$success" ]; then
  ab_pass_with_evidence "K2: $P concurrent logins issued $distinct DISTINCT independent sessions, no deadlock" "$ev"
else
  ab_fail "K2: success=$success distinct=$distinct/$P deadlock=$deadlocked (want P distinct sessions) [ev: ${ev#$HC_ROOT/}]"
fi
# K3 assertion (atomic issuance: every success = a complete, authorizing cookie)
ev3="$(h_ev k3_atomic)"
{ echo "=== (K3) atomic cookie issuance ===";
  echo "successes=$success authorized=$authorized (want equal — every login cookie routes through the gate, none stays 401)"; } > "$ev3"
if [ "$success" -ge 1 ] && [ "$authorized" = "$success" ]; then
  ab_pass_with_evidence "K3: every one of $success concurrent sessions carried a complete, authorizing cookie (atomic)" "$ev3"
else
  ab_fail "K3: successes=$success authorized=$authorized (want equal, >=1) [ev: ${ev3#$HC_ROOT/}]"
fi

# =========================================================================
# (K4) REPLAY-GUARD EXACTLY-ONCE under concurrency (single-use nonce).
# =========================================================================
h_head "(K4) replay-guard: same signed challenge x$P in parallel -> exactly one succeeds"
ev="$(h_ev k4_replay)"
CJAR="$WORK/k4chal"; CPAGE="$WORK/k4page"; : > "$CJAR"
# ONE GET /login into a SHARED jar: captures the __Host-helix_csrf cookie AND (in
# HC_SSHKEY_HIDDEN) the matching csrf_token + the single challenge_token. Every
# worker reuses this ONE CSRF pair + ONE challenge, so the only single-use element
# under test is the challenge NONCE (the replay guard) — never the CSRF check
# (which would otherwise 403 every fresh-jar worker and mask the replay result).
if hc_sshkey_challenge "$TARGET" "$CJAR" "$CPAGE"; then
  SIG=""; _sign3 "$HC_SSHKEY_NONCE" "$TKEY" "$WORK/k4.sig0" && SIG="$(cat "$WORK/k4.sig0")"
  K4_HIDDEN="$HC_SSHKEY_HIDDEN"                       # snapshot the one challenge's hidden fields
  K4_CSRFNAME="$(hc_jar_names "$CJAR" | grep -m1 . || true)"; K4_CSRFNAME="${K4_CSRFNAME:-__Host-helix_csrf}"
  if printf '%s' "$SIG" | grep -q 'BEGIN SSH SIGNATURE'; then
    _replay_worker() { # <id> — replay the ONE signed challenge, SHARING the CSRF
      # cookie READ-ONLY from $CJAR (curl -b, never -c => no jar write race), sending
      # the shared csrf_token + challenge_token + signature. A per-worker header dump
      # captures the response Set-Cookie so a WIN carries positive session proof.
      local id="$1" st="$WORK/k4s$1" hdr="$WORK/k4h$1"
      local -a args=(); local had_sig=0 line name val
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        name="${line%%=*}"; val="${line#*=}"
        [ "$name" = signature ] && { val="$SIG"; had_sig=1; }
        [ "$name" = principal ] && val="$PRINCIPAL"
        args+=(--data-urlencode "$name=$val")
      done <<EOF
$K4_HIDDEN
EOF
      [ "$had_sig" = 1 ] || args+=(--data-urlencode "signature=$SIG")
      printf '%s\n' "$K4_HIDDEN" | grep -q '^principal=' || args+=(--data-urlencode "principal=$PRINCIPAL")
      local code sc
      code="$(curl -k -s -b "$CJAR" -D "$hdr" -o /dev/null -w '%{http_code}' --max-time 20 "${args[@]}" "$TARGET/login" 2>/dev/null || echo 000)"
      # WIN = the gate accepted THIS replay: a 302/303 redirect AND a NON-empty
      # session cookie set (a Set-Cookie with a non-empty value whose name != the
      # CSRF cookie — the 401 replay path only re-mints a fresh CSRF cookie, never a
      # session, so this positively distinguishes the single winner from replays).
      sc="$(grep -iE '^set-cookie:' "$hdr" 2>/dev/null | grep -E '=[^;[:space:]]' | grep -v "$K4_CSRFNAME" || true)"
      if { [ "$code" = 302 ] || [ "$code" = 303 ]; } && [ -n "$sc" ]; then echo "WIN $code" > "$st"; else echo "DENY $code" > "$st"; fi
    }
    pids=""; i=0; while [ "$i" -lt "$P" ]; do i=$((i+1)); _replay_worker "$i" & pids="$pids $!"; done
    deadlocked=0
    for pid in $pids; do w=0; while kill -0 "$pid" 2>/dev/null; do sleep 1; w=$((w+1)); [ "$w" -ge 90 ] && { kill "$pid" 2>/dev/null||true; deadlocked=1; break; }; done; wait "$pid" 2>/dev/null||true; done
    wins=0; denies=0; i=0
    while [ "$i" -lt "$P" ]; do i=$((i+1)); st="$WORK/k4s$i"; grep -q '^WIN' "$st" 2>/dev/null && wins=$((wins+1)); grep -q '^DENY' "$st" 2>/dev/null && denies=$((denies+1)); done
    { echo "=== (K4) replay-guard exactly-once under concurrency ===";
      echo "one challenge signed once, POSTed by P=$P parallel requests (shared CSRF cookie, read-only)";
      echo "successes (WIN, 302/303 + new session cookie): $wins (want EXACTLY 1)";
      echo "denied (DENY, 401 replay / no session cookie) : $denies (want $((P-1)))";
      echo "deadlocked (>90s)                     : $deadlocked (want 0)";
      echo "per-worker:"; for i in $(seq 1 "$P"); do echo "  w$i: $(cat "$WORK/k4s$i" 2>/dev/null || echo '<none>')"; done; } > "$ev"
    if [ "$deadlocked" = 0 ] && [ "$wins" = 1 ] && [ "$denies" = "$((P-1))" ]; then
      ab_pass_with_evidence "K4: single-use nonce enforced under concurrency — exactly 1 of $P replays succeeded, $denies denied" "$ev"
    else
      ab_fail "K4: wins=$wins denies=$denies/$P deadlock=$deadlocked (want exactly 1 win) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    { echo "could not sign the challenge nonce with the provided key (no armored signature)"; } > "$ev"
    ab_fail "K4: signing the challenge failed [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "could not obtain a login challenge from $TARGET/login"; } > "$ev"
  ab_fail "K4: no login challenge to replay [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
# (K5) NO SESSION FIXATION — session id changes on login.
# =========================================================================
h_head "(K5) no session fixation: authenticated session id differs from pre-login cookie"
ev="$(h_ev k5_fixation)"
FJAR="$WORK/k5jar"; FPAGE="$WORK/k5page"; : > "$FJAR"
if hc_sshkey_challenge "$TARGET" "$FJAR" "$FPAGE"; then
  pre_names="$(hc_jar_names "$FJAR" | sort -u | tr '\n' ',' )"
  pre_fp="$(_jar_fp "$FJAR")"
  SIG=""; _sign3 "$HC_SSHKEY_NONCE" "$TKEY" "$WORK/k5.sig0" && SIG="$(cat "$WORK/k5.sig0")"
  hc_sshkey_submit "$TARGET" "$FJAR" "$SIG" "$PRINCIPAL" || true
  post_fp="$(_jar_fp "$FJAR")"
  newcookie="${HC_SSHKEY_NEWCOOKIE:-}"
  changed=0; [ "$pre_fp" != "$post_fp" ] && changed=1
  succeeded=0; { [ "$HC_SSHKEY_CODE" = 302 ] || [ "$HC_SSHKEY_CODE" = 303 ]; } && succeeded=1
  { echo "=== (K5) no session fixation ===";
    echo "pre-login cookie names : ${pre_names:-<none>}";
    echo "pre-login jar fingerprint (sha256, values NEVER shown §11.4.10) : ${pre_fp:-<none>}";
    echo "login POST code         : $HC_SSHKEY_CODE (want 302/303)";
    echo "new cookie appeared post-auth : ${newcookie:-<none>}";
    echo "post-login jar fingerprint : ${post_fp:-<none>}";
    echo "session material CHANGED on login : $([ $changed = 1 ] && echo yes || echo no) (want yes)"; } > "$ev"
  if [ "$succeeded" = 1 ] && [ "$changed" = 1 ]; then
    ab_pass_with_evidence "K5: session identifier changed on authentication (no fixation; new cookie=${newcookie:-<rotated>})" "$ev"
  else
    ab_fail "K5: login_ok=$succeeded session_changed=$changed (want 1/1 — session id must change on login) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "could not obtain a login challenge from $TARGET/login"; } > "$ev"
  ab_fail "K5: no login challenge to test fixation [ev: ${ev#$HC_ROOT/}]"
fi

h_summary
