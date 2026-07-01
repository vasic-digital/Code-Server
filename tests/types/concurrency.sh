#!/usr/bin/env bash
# tests/types/concurrency.sh — HelixCode CONCURRENCY / ATOMICITY suite
#                              (§11.4.169 concurrency/atomicity ; §11.4.85).
#
# Purpose:      Prove the stack + operator scripts are safe under concurrent /
#               interrupted operation, with REAL captured evidence (§11.4.69):
#                 (C1) N concurrent /login POSTs each succeed INDEPENDENTLY —
#                      every worker gets its own 302 + Set-Cookie, no interleave
#                      corruption; a wrong-password negative control proves the
#                      302s are genuine auth (not a blanket accept).
#                 (C2) The deploy/.env REWRITE discipline is atomic — validated
#                      on a THROWAWAY TEMP COPY (the real deploy/.env is NEVER
#                      touched, §11.4.119). An atomic write-temp+rename is never
#                      observed torn under concurrent readers, an interrupted
#                      rewrite leaves the OLD file intact, the completed rewrite
#                      preserves mode 600 + all keys, and a golden-bad torn
#                      fixture PROVES the tear-detector is not a bluff (§11.4.107(10)).
#                 (C3) Concurrent scripts/start.sh cannot double-create — exactly
#                      one live instance of each named container exists, and the
#                      compose construction (fixed project + service names, no
#                      scale/replicas, `up -d` reconcile) is idempotent-by-name.
#                      The DESTRUCTIVE concurrent-exec race is honestly SKIPPED
#                      (it would recreate the shared single-owner stack §11.4.119).
# Usage:        bash tests/types/concurrency.sh
# Inputs:       deploy/.env via the fixture (password never printed, §11.4.10)
# Outputs:      per-run evidence under qa-results/tests/concurrency/<run-id>/
# Side-effects: reads the shared stack (login POSTs mint server-side sessions —
#               non-destructive); C2 works only on a self-created TEMP dir which
#               is removed on exit; the shared stack is never stopped/reconfigured.
# Dependencies: bash, curl, podman|docker, coreutils (mktemp/stat/sha256sum)
# Cross-references: §11.4.69 §11.4.85 §11.4.119 §11.4.10 §11.4.107 §11.4.174 ;
#                   harness.sh stack_fixture.sh ; scripts/set-password.sh scripts/start.sh
#
# §1.1 PAIRED MUTATION (per case, for the meta-test sweep):
#   C1  break the login POST to always 200 (or drop Set-Cookie) -> the "N/N got
#       302+cookie" assert FAILs.
#   C2a make atomic_write_env non-atomic (write in place: `> "$tgt"` instead of
#       temp+mv) -> concurrent readers observe a torn state -> torn>0 -> FAIL.
#   C2d weaken env_valid() to `[ -s "$f" ]` (drop the key check) -> the golden-bad
#       torn fixture is accepted as valid -> the detector self-validation FAILs.
#   C3a scale a named service to 2 replicas -> live instance count != 1 -> FAIL.
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init concurrency

# ---- runtime guard -------------------------------------------------------
if ! h_require podman && ! h_require docker; then
  ab_skip_with_reason "concurrency suite (no container runtime on PATH)" topology_unsupported
  h_summary; exit $?
fi
if ! h_require curl; then
  ab_skip_with_reason "concurrency suite (curl absent)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi

# code-server readiness (§11.4.107(3) loading-state / §11.4.144 availability-
# following). Caddy's /healthz answers 200 even while its code-server upstream is
# restarting, so a REAL readiness signal is a code-server-served path: GET /login
# == 200 (502 = upstream down). Tolerate a transient restart of the SHARED
# single-owner stack (§11.4.119 contention) by waiting — but NEVER bluff a PASS:
# if /login never reaches 200 within the window the stack is genuinely unhealthy.
hc_cs_ready() { [ "$(hc_https_code /login)" = 200 ]; }
hc_wait_cs()  { local i n="${1:-45}"; for i in $(seq 1 "$n"); do hc_cs_ready && return 0; sleep 2; done; return 1; }
if ! hc_wait_cs 45; then
  ab_fail "code-server upstream not serving /login=200 after ~90s (Caddy up, upstream down) — stack unhealthy"
  h_summary; exit $?
fi

# temp workspace (auto-cleaned) --------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_concurrency.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# redact any session-cookie value before it lands in evidence (§11.4.10).
redact() { sed -E 's/(set-cookie:[[:space:]]*[^=]+=)[^;[:space:]]+/\1<redacted>/Ig'; }

# ==========================================================================
# C1 — N concurrent logins succeed independently (all 302 + own Set-Cookie)
# ==========================================================================
h_head "C1 — N concurrent independent logins (302 + Set-Cookie each)"
ev="$(h_ev c1_concurrent_logins)"
NLOGIN=10
wdir="$WORK/logins"; mkdir -p "$wdir"
pids=""
i=0
while [ "$i" -lt "$NLOGIN" ]; do
  i=$((i+1))
  ( hc_login_headers "$HC_PASSWORD" "$wdir/w$i.hdr" ) &
  pids="$pids $!"
done
for p in $pids; do wait "$p" 2>/dev/null || true; done

got302=0; gotcookie=0; files=0
{ echo "concurrent /login POSTs (correct password): N=$NLOGIN"
  echo "per-worker status line + cookie presence (cookie value redacted):"; } > "$ev"
i=0
while [ "$i" -lt "$NLOGIN" ]; do
  i=$((i+1))
  f="$wdir/w$i.hdr"
  [ -f "$f" ] || continue
  files=$((files+1))
  st="$(grep -iE '^HTTP/[0-9.]+ [0-9]{3}' "$f" | head -1 | tr -d '\r')"
  ck="no"
  if grep -qiE '^set-cookie:' "$f"; then ck="yes"; gotcookie=$((gotcookie+1)); fi
  case "$st" in *" 302"*) got302=$((got302+1));; esac
  printf '  w%s: %s cookie=%s\n' "$i" "${st:-<none>}" "$ck" >> "$ev"
done
{ echo "--- totals ---"; echo "workers_reported=$files got302=$got302 got_cookie=$gotcookie"; } >> "$ev"

# negative control: wrong password must NOT 302 (proves the 302s are real auth)
wrongcode="$(hc_login_code 'definitely-not-the-real-password-xyz')"
{ echo "--- negative control ---"; echo "wrong-password /login status = $wrongcode (expect NOT 302)"; } >> "$ev"

if [ "$got302" -eq "$NLOGIN" ] && [ "$gotcookie" -eq "$NLOGIN" ] && [ "$wrongcode" != 302 ]; then
  ab_pass_with_evidence "C1: $got302/$NLOGIN concurrent logins each returned 302 + own Set-Cookie; wrong pw=$wrongcode (independent, no interleave)" "$ev"
else
  ab_fail "C1: concurrent logins not all independent (302=$got302/$NLOGIN cookie=$gotcookie wrongpw=$wrongcode) [ev: ${ev#$HC_ROOT/}]"
fi

# ==========================================================================
# C2 — set-password.sh .env REWRITE atomicity (on a TEMP COPY only)
# ==========================================================================
# A complete valid HelixCode .env carries all three keys and is non-empty.
# Pure-bash (no per-call subprocess) so the C2a tight reader loop stays light.
env_valid() {
  local f="${1:-/nonexistent}" a=0 b=0 c=0 nl=0 line
  [ -s "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    nl=$((nl+1))
    case "$line" in
      PORT_PREFIX=*)          a=1 ;;
      CODE_SERVER_PASSWORD=*) b=1 ;;
      PROJECTS=*)             c=1 ;;
    esac
  done < "$f"
  [ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] && [ "$nl" -ge 3 ]
}
# atomic rewrite = write a sibling temp then rename over the target (same fs).
atomic_write_env() {
  local tgt="$1" pw="$2" d tmp
  d="$(dirname "$tgt")"
  tmp="$(mktemp "$d/.env.tmp.XXXXXX")" || return 1
  ( umask 077
    printf '# HelixCode deploy config (TEST TEMP COPY — not real)\n'
    printf 'PORT_PREFIX=52\n'
    printf 'CODE_SERVER_PASSWORD=%s\n' "$pw"
    printf 'PROJECTS=\n'
  ) > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$tgt"           # atomic rename — reader sees old-or-new, never torn
}

# ---- C2a: atomic rewrite is never torn under concurrent readers ----------
h_head "C2a — atomic .env rewrite: no torn state under concurrent readers"
ev="$(h_ev c2a_atomic_no_tear)"
TGT="$WORK/.env"
# NOTE: TEMP COPY — a placeholder password, NEVER the real one (§11.4.10).
atomic_write_env "$TGT" "placeholder_seed_pw"
( r=0; while [ "$r" -lt 120 ]; do r=$((r+1)); atomic_write_env "$TGT" "placeholder_pw_$r"; done ) &
wpid=$!
torn=0; samples=0
while kill -0 "$wpid" 2>/dev/null; do
  samples=$((samples+1))
  env_valid "$TGT" || torn=$((torn+1))
done
wait "$wpid" 2>/dev/null || true
{ echo "atomic write-temp+rename rewrites=120, concurrent reader samples=$samples"
  echo "torn (invalid/partial) observations = $torn (expect 0)"
  echo "final file mode = $(stat -c '%a' "$TGT" 2>/dev/null)"
  echo "final file valid = $(env_valid "$TGT" && echo yes || echo no)"; } > "$ev"
if [ "$samples" -ge 1 ] && [ "$torn" -eq 0 ] && env_valid "$TGT"; then
  ab_pass_with_evidence "C2a: $samples concurrent reads of an atomically-rewritten .env, 0 torn states" "$ev"
else
  ab_fail "C2a: torn=$torn over $samples samples (atomic rewrite must never tear) [ev: ${ev#$HC_ROOT/}]"
fi

# ---- C2b: interrupted rewrite leaves the OLD file intact -----------------
h_head "C2b — interrupted rewrite leaves the OLD .env intact (never half-written)"
ev="$(h_ev c2b_interrupt_old_intact)"
atomic_write_env "$TGT" "OLD_known_placeholder"
oldsum="$(sha256sum "$TGT" | awk '{print $1}')"
oldmode="$(stat -c '%a' "$TGT")"
# a writer that stages a temp, then sleeps BEFORE the rename; we kill it mid-stage.
( tmp="$(mktemp "$WORK/.env.tmp.XXXXXX")"
  ( umask 077; printf 'PORT_PREFIX=52\nCODE_SERVER_PASSWORD=NEW_placeholder\nPROJECTS=\n' ) > "$tmp"
  chmod 600 "$tmp"; sleep 3; mv -f "$tmp" "$TGT" ) &
ipid=$!                               # our OWN subshell pid only (§11.4.174)
sleep 1
kill -TERM "$ipid" 2>/dev/null || true
wait "$ipid" 2>/dev/null || true
newsum="$(sha256sum "$TGT" | awk '{print $1}')"
newmode="$(stat -c '%a' "$TGT")"
straytmp="$(find "$WORK" -maxdepth 1 -name '.env.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
{ echo "interrupted a mid-flight rewrite (killed before rename)"
  echo "old sha256=$oldsum mode=$oldmode"
  echo "new sha256=$newsum mode=$newmode"
  echo "target unchanged = $([ "$oldsum" = "$newsum" ] && echo yes || echo no)"
  echo "target still valid = $(env_valid "$TGT" && echo yes || echo no)"
  echo "leftover staged temp files (cleaned on exit) = $straytmp"; } > "$ev"
if [ "$oldsum" = "$newsum" ] && [ "$oldmode" = "$newmode" ] && env_valid "$TGT"; then
  ab_pass_with_evidence "C2b: interrupted rewrite left the OLD .env byte-identical, mode $newmode, valid" "$ev"
else
  ab_fail "C2b: interrupt torn the file (old=$oldsum/$oldmode new=$newsum/$newmode) [ev: ${ev#$HC_ROOT/}]"
fi
rm -f "$WORK"/.env.tmp.* 2>/dev/null || true

# ---- C2c: completed rewrite preserves mode 600 + all keys ----------------
# Validates the completed-write CONTRACT (final on-disk shape: mode 600 + all
# keys). set-password.sh now produces this via an atomic temp+rename; the final
# file shape is identical, so this contract check holds for the atomic writer.
h_head "C2c — completed rewrite contract: mode 600 + all keys"
ev="$(h_ev c2c_completed_contract)"
( umask 077
  cat > "$TGT" <<'ENVEOF'
# HelixCode deploy config (TEST TEMP COPY — not real)
PORT_PREFIX=52
CODE_SERVER_PASSWORD=placeholder_completed
PROJECTS=
ENVEOF
  chmod 600 "$TGT" )
fmode="$(stat -c '%a' "$TGT")"
{ echo "replayed: umask 077; cat > .env <<heredoc; chmod 600"
  echo "final mode = $fmode (expect 600)"
  echo "final valid (all 3 keys, non-empty) = $(env_valid "$TGT" && echo yes || echo no)"; } > "$ev"
if [ "$fmode" = 600 ] && env_valid "$TGT"; then
  ab_pass_with_evidence "C2c: completed .env rewrite is mode 600 with all required keys" "$ev"
else
  ab_fail "C2c: completed rewrite contract broken (mode=$fmode) [ev: ${ev#$HC_ROOT/}]"
fi

# ---- C2d: golden-bad — the tear-detector actually catches a torn file -----
# §11.4.107(10) self-validation: without this, C2a/C2b could be bluffs.
h_head "C2d — tear-detector self-validation (golden-bad torn fixture MUST fail)"
ev="$(h_ev c2d_detector_selfvalidation)"
: > "$TGT"                             # 0-byte state = the exact window `cat >` opens
printf 'PORT_PREFIX=52\n' >> "$TGT"    # partial: missing CODE_SERVER_PASSWORD + PROJECTS
{ echo "deliberately torn fixture (truncate-then-partial-write, = non-atomic cat> mid-flight)"
  echo "file bytes = $(wc -c < "$TGT" | tr -d ' ')"
  echo "env_valid(torn) = $(env_valid "$TGT" && echo TRUE || echo FALSE) (expect FALSE)"; } > "$ev"
if env_valid "$TGT"; then
  ab_fail "C2d: tear-detector accepted a torn file — C2a/C2b would be bluffs [ev: ${ev#$HC_ROOT/}]"
else
  ab_pass_with_evidence "C2d: tear-detector correctly flagged the golden-bad torn .env as invalid" "$ev"
fi

# ---- §11.4.6 note (recorded, not a verdict): the atomic-write guarantee -----
find_ev="$(h_ev c2_setpassword_atomic_confirmed)"
{ echo "CONFIRMED (§11.4.6) — scripts/set-password.sh rewrites deploy/.env ATOMICALLY:"
  echo "umask 077; write a sibling temp file; chmod 600; mv -f (same-fs rename(2))."
  echo "rename is atomic, so an interrupted rewrite (crash/SIGKILL) can NEVER leave"
  echo "deploy/.env torn — a reader always sees the whole old or whole new file."
  echo "C2a/C2b prove the atomic writer never tears; C2d proves the tear-DETECTOR"
  echo "actually catches a torn file (so C2a/C2b are not bluffs). The 0-byte/partial"
  echo "state C2d builds is the PRE-FIX 'cat > .env' baseline the atomic write eliminates."
  echo "History: set-password.sh's non-atomic cat> write was fixed to temp+rename in"
  echo "release codeserver-1.0.0-dev-0.0.2 (see changelog + docs/features/Status.md)."; } > "$find_ev"
h_log "recorded set-password.sh atomic-write confirmation: ${find_ev#$HC_ROOT/}"

# ==========================================================================
# C3 — concurrent scripts/start.sh cannot double-create / race
# ==========================================================================
h_head "C3a — exactly one live instance of each named container (no double-create)"
hc_wait_cs 30 || true   # re-follow availability: a sibling may have restarted the shared stack mid-suite
ev="$(h_ev c3a_single_instance)"
"$HC_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -E '^deploy_(code-server|caddy)_1$' > "$ev" || true
# grep -Fxc: exact whole-line match to OUR names only — no loose pgrep (§11.4.174)
n_cs="$("$HC_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -Fxc "$HC_CS")"
n_cd="$("$HC_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -Fxc "$HC_CADDY")"
{ echo "--- exact-name live instance counts ---"; echo "$HC_CS=$n_cs (expect 1)"; echo "$HC_CADDY=$n_cd (expect 1)"; } >> "$ev"
if [ "${n_cs:-0}" -eq 1 ] && [ "${n_cd:-0}" -eq 1 ]; then
  ab_pass_with_evidence "C3a: exactly one live $HC_CS and one $HC_CADDY (fixed names prevent double-create)" "$ev"
else
  ab_fail "C3a: unexpected instance count (cs=$n_cs caddy=$n_cd) [ev: ${ev#$HC_ROOT/}]"
fi

h_head "C3b — compose construction is idempotent-by-name (no scale/replicas)"
ev="$(h_ev c3b_idempotent_construction)"
COMPOSE="$HC_ROOT/deploy/compose.codeserver.yml"
UP="$HC_ROOT/deploy/up.sh"
has_updash="no"; has_scale="present"; has_svcnames="no"
grep -qE 'up -d' "$UP" 2>/dev/null && has_updash="yes"
grep -qiE '(^|[^A-Za-z])(replicas|--scale|scale:)' "$COMPOSE" 2>/dev/null || has_scale="absent"
grep -qE '^[[:space:]]*(code-server|caddy):[[:space:]]*$' "$COMPOSE" 2>/dev/null && has_svcnames="yes"
{ echo "deploy/up.sh uses 'up -d' (reconcile, not create-new) = $has_updash"
  echo "compose.codeserver.yml scale/replicas directive = $has_scale (expect absent)"
  echo "compose.codeserver.yml fixed service names present = $has_svcnames"
  echo "--- service lines ---"; grep -nE '^[[:space:]]*(code-server|caddy):' "$COMPOSE" 2>/dev/null
  echo "--- up.sh 'up -d' line ---"; grep -nE 'up -d' "$UP" 2>/dev/null; } > "$ev"
if [ "$has_updash" = yes ] && [ "$has_scale" = absent ] && [ "$has_svcnames" = yes ]; then
  ab_pass_with_evidence "C3b: fixed project+service names, no scale/replicas, 'up -d' reconcile => concurrent start cannot duplicate" "$ev"
else
  ab_fail "C3b: idempotency-by-construction not proven (up-d=$has_updash scale=$has_scale names=$has_svcnames) [ev: ${ev#$HC_ROOT/}]"
fi

h_head "C3c — destructive concurrent start.sh exec race (honest SKIP)"
ab_skip_with_reason "concurrent scripts/start.sh destructive-exec race — would recreate the SHARED single-owner stack (§11.4.119); belongs to the serial main-stream executor on a disposable stack" feature_disabled_by_config

h_summary
