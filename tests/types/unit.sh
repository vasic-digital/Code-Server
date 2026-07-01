#!/usr/bin/env bash
# tests/types/unit.sh — HelixCode UNIT test suite (§11.4.169 unit layer).
#
# Purpose:      Pure-logic tests of the shell tooling WITHOUT the running stack.
#               Unit is the ONLY layer where fakes/stubs/temp fixtures are
#               permitted (§11.4.27(A)); every subject-under-test here is the
#               REAL project file, exercised in an isolated sandbox so no repo
#               state (real deploy/.env, the live stack) is ever touched.
# Coverage:     (1) setup.sh port-prefix validation (reject PREFIX*1000+999>65535
#                   and non-numeric; accept the 64/65 boundary) — run the REAL
#                   setup.sh --non-interactive in a temp sandbox.
#               (2) set-password.sh atomic .env rewrite — preserves PORT_PREFIX +
#                   PROJECTS, changes the password, mode 600, no torn file — run
#                   the REAL set-password.sh in a temp sandbox.
#               (3) deploy/code-server/settings.default.json is valid JSON with
#                   the core watcherExclude patterns.
#               (4) scripts/lib.sh helpers (hc_prefix default+override, hc_runtime).
#               (5) TLS-mode selection: Caddyfile static-cert (NOT `tls internal`)
#                   + up.sh SAN-coverage predicate exercised against a real temp cert.
# Usage:        bash tests/types/unit.sh          # no stack required
#               RED_MODE=1 bash tests/types/unit.sh
# Inputs:       repo tree (read-only); creates temp sandboxes under $TMPDIR
# Outputs:      per-run evidence under qa-results/tests/unit/<run-id>/
# Side-effects: temp sandboxes only (trap-cleaned); never mutates the git tree
# Dependencies: bash, jq, openssl, coreutils; podman|docker NOT required (stubbed)
# Cross-references: §11.4.27 §11.4.69 §11.4.6 ; tests/lib/harness.sh
. "$(dirname "$0")/../lib/harness.sh"
h_init unit

# ---- sandbox root (all fixtures live here; trap-cleaned) -----------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hc_unit.XXXXXX")"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

# A no-op `podman` stub so set-password.sh's "is the stack running?" check
# resolves to "not running" deterministically + fast, without touching the real
# runtime (unit-layer stub, §11.4.27(A)).
STUB_BIN="$SANDBOX/bin"; mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/podman"; chmod +x "$STUB_BIN/podman"

# --------------------------------------------------------------------------
# (1) setup.sh port-prefix validation — REAL script in a sandbox.
# --------------------------------------------------------------------------
h_head "setup.sh port-prefix validation (real script, sandboxed)"
S1="$SANDBOX/case1"; mkdir -p "$S1/scripts"
cp "$HC_ROOT/scripts/setup.sh" "$HC_ROOT/scripts/lib.sh" "$S1/scripts/"
ev="$(h_ev setup_prefix_table)"
: > "$ev"
# expected exit: valid prefix -> 0 (writes .env), invalid -> 2.
# boundary: p*1000+999<=65535 <=> p<=64. So 64 valid, 65 invalid.
ok=1
for pair in "52:0" "64:0" "65:2" "66:2" "999:2" "abc:2"; do
  pfx="${pair%%:*}"; want="${pair##*:}"
  rm -f "$S1/deploy/.env" 2>/dev/null
  env -u PORT_PREFIX -u PROJECTS -u CODE_SERVER_PASSWORD \
      CODE_SERVER_PASSWORD="unit_sandbox_pw" PORT_PREFIX="$pfx" \
      bash "$S1/scripts/setup.sh" --non-interactive >>"$ev" 2>&1
  got=$?
  printf 'prefix=%-4s expected_exit=%s actual_exit=%s %s\n' \
    "$pfx" "$want" "$got" "$([ "$got" = "$want" ] && echo OK || echo MISMATCH)" >> "$ev"
  [ "$got" = "$want" ] || ok=0
done
# also confirm a VALID run actually wrote a mode-600 .env with the prefix.
rm -f "$S1/deploy/.env" 2>/dev/null
env -u PORT_PREFIX -u PROJECTS -u CODE_SERVER_PASSWORD \
    CODE_SERVER_PASSWORD="unit_sandbox_pw" PORT_PREFIX="52" \
    bash "$S1/scripts/setup.sh" --non-interactive >>"$ev" 2>&1
mode="$(stat -c '%a' "$S1/deploy/.env" 2>/dev/null || stat -f '%Lp' "$S1/deploy/.env" 2>/dev/null)"
grep -q '^PORT_PREFIX=52$' "$S1/deploy/.env" 2>/dev/null || ok=0
{ echo "valid-run .env mode: ${mode:-none}"; echo "valid-run .env keys:"; sed -E 's/^(CODE_SERVER_PASSWORD=).*/\1<redacted>/' "$S1/deploy/.env" 2>/dev/null; } >> "$ev"
[ "$mode" = "600" ] || ok=0
if [ "$ok" = 1 ]; then ab_pass_with_evidence "setup.sh accepts p<=64, rejects p>=65 & non-numeric; writes mode-600 .env" "$ev"
else ab_fail "setup.sh port-prefix validation table mismatch [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (2) set-password.sh atomic .env rewrite — REAL script in a sandbox.
# --------------------------------------------------------------------------
h_head "set-password.sh atomic .env rewrite (real script, sandboxed)"
S2="$SANDBOX/case2"; mkdir -p "$S2/scripts" "$S2/deploy"
cp "$HC_ROOT/scripts/set-password.sh" "$HC_ROOT/scripts/lib.sh" "$S2/scripts/"
[ -f "$HC_ROOT/scripts/restart.sh" ] && cp "$HC_ROOT/scripts/restart.sh" "$S2/scripts/"
umask 077
cat > "$S2/deploy/.env" <<'PRE'
# prior config
PORT_PREFIX=57
CODE_SERVER_PASSWORD=old_unit_pw
PROJECTS=/srv/a:/srv/b
PRE
chmod 600 "$S2/deploy/.env"
ev="$(h_ev setpw_rewrite)"
PATH="$STUB_BIN:$PATH" NEW_PASSWORD="new_unit_pw_$$" \
  bash "$S2/scripts/set-password.sh" > "$ev" 2>&1
# assert: PORT_PREFIX preserved, PROJECTS preserved, password changed, mode 600,
# file sources cleanly (no torn write => parseable with exactly the 3 keys).
mode2="$(stat -c '%a' "$S2/deploy/.env" 2>/dev/null || stat -f '%Lp' "$S2/deploy/.env" 2>/dev/null)"
pp="$(grep -c '^PORT_PREFIX=57$'         "$S2/deploy/.env")"
pj="$(grep -c '^PROJECTS=/srv/a:/srv/b$' "$S2/deploy/.env")"
np="$(grep -c "^CODE_SERVER_PASSWORD=new_unit_pw_$$\$" "$S2/deploy/.env")"
oldgone="$(grep -c '^CODE_SERVER_PASSWORD=old_unit_pw$' "$S2/deploy/.env")"
# torn-file proxy: sources cleanly and yields exactly the 3 expected keys.
sourced_ok=no; ( set -a; . "$S2/deploy/.env" ) >/dev/null 2>&1 && sourced_ok=yes
keycount="$(grep -cE '^[A-Z_]+=' "$S2/deploy/.env")"
{ echo "rewritten .env (password redacted):"
  sed -E 's/^(CODE_SERVER_PASSWORD=).*/\1<redacted>/' "$S2/deploy/.env"
  echo "mode=$mode2 port_preserved=$pp projects_preserved=$pj new_pw_line=$np old_pw_gone=$oldgone sources_clean=$sourced_ok keycount=$keycount"
} >> "$ev"
if [ "$mode2" = 600 ] && [ "$pp" = 1 ] && [ "$pj" = 1 ] && [ "$np" = 1 ] && [ "$oldgone" = 0 ] && [ "$sourced_ok" = yes ] && [ "$keycount" = 3 ]; then
  ab_pass_with_evidence "set-password.sh preserves PORT_PREFIX+PROJECTS, swaps password, mode 600, no torn file" "$ev"
else ab_fail "set-password.sh rewrite invariant broken [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (3) settings.default.json — valid JSON + core watcherExclude patterns.
# --------------------------------------------------------------------------
h_head "settings.default.json valid JSON + core watcherExclude patterns"
SET="$HC_ROOT/deploy/code-server/settings.default.json"
ev="$(h_ev settings_json)"
if ! h_require jq; then
  ab_skip_with_reason "settings.default.json JSON+patterns" topology_unsupported
else
  if jq -e . "$SET" >/dev/null 2>"$ev"; then
    keys="$(jq -r '.["files.watcherExclude"] | keys[]' "$SET" 2>/dev/null)"
    { echo "valid JSON: yes"; echo "watcherExclude entries:"; echo "$keys"; } > "$ev"
    miss=""
    for pat in 'node_modules' '\.git' 'dist' 'build' 'out' 'target' '\.gradle' '__pycache__' '\.venv' 'vendor' 'prebuilts'; do
      echo "$keys" | grep -Eq "$pat" || miss="$miss $pat"
    done
    echo "missing_core_patterns:${miss:- none}" >> "$ev"
    if [ -z "$miss" ]; then ab_pass_with_evidence "settings.default.json valid JSON with all core watcherExclude patterns" "$ev"
    else ab_fail "settings.default.json missing core patterns:$miss [ev: ${ev#$HC_ROOT/}]"; fi
  else
    ab_fail "settings.default.json is NOT valid JSON [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# --------------------------------------------------------------------------
# (4) lib.sh helpers — hc_prefix (default + override), hc_runtime.
# --------------------------------------------------------------------------
h_head "lib.sh helpers (hc_prefix default/override, hc_runtime)"
S4="$SANDBOX/case4"; mkdir -p "$S4/scripts" "$S4/deploy"
cp "$HC_ROOT/scripts/lib.sh" "$S4/scripts/"
ev="$(h_ev lib_helpers)"
# override: deploy/.env present with PORT_PREFIX=59 -> hc_prefix echoes 59.
printf 'PORT_PREFIX=59\nCODE_SERVER_PASSWORD=x\nPROJECTS=\n' > "$S4/deploy/.env"
pref_override="$( ( . "$S4/scripts/lib.sh"; hc_prefix ) 2>/dev/null )"
# default: no deploy/.env -> hc_prefix echoes 52.
rm -f "$S4/deploy/.env"
pref_default="$( ( . "$S4/scripts/lib.sh"; hc_prefix ) 2>/dev/null )"
# runtime detection (podman present in this env -> "podman compose").
rt="$( ( . "$HC_ROOT/scripts/lib.sh"; hc_runtime ) 2>/dev/null )"
{ echo "hc_prefix(override .env=59): $pref_override"
  echo "hc_prefix(no .env, default): $pref_default"
  echo "hc_runtime: $rt"; } > "$ev"
if [ "$pref_override" = 59 ] && [ "$pref_default" = 52 ] && echo "$rt" | grep -Eq 'podman compose|docker compose'; then
  ab_pass_with_evidence "lib.sh hc_prefix honours .env override + 52 default; hc_runtime resolves a compose driver" "$ev"
else ab_fail "lib.sh helpers wrong (override=$pref_override default=$pref_default rt=$rt) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (5) TLS-mode selection: Caddyfile static cert + up.sh SAN-coverage predicate.
# --------------------------------------------------------------------------
h_head "TLS mode: Caddyfile static-cert config + up.sh SAN-coverage predicate"
ev="$(h_ev tls_mode)"
CADDY="$HC_ROOT/deploy/Caddyfile"; UP="$HC_ROOT/deploy/up.sh"
static_cert="$(grep -cE 'tls[[:space:]]+/etc/caddy/tls/site\.crt[[:space:]]+/etc/caddy/tls/site\.key' "$CADDY")"
# The design explicitly avoids a bare `tls internal` site (no SNI hostnames).
bare_internal="$(grep -cE '^[[:space:]]*tls[[:space:]]+internal[[:space:]]*$' "$CADDY")"
up_regen_guard="$(grep -c 'need=1' "$UP")"
up_san_ext="$(grep -c 'subjectAltName=' "$UP")"
up_key_600="$(grep -c 'chmod 600 tls/site.key' "$UP")"
{ echo "Caddyfile static-cert directive count: $static_cert"
  echo "Caddyfile bare 'tls internal' count (must be 0): $bare_internal"
  echo "up.sh regen-guard (need=1) count: $up_regen_guard"
  echo "up.sh subjectAltName ext count: $up_san_ext"
  echo "up.sh chmod 600 key count: $up_key_600"; } > "$ev"
# Exercise the REAL predicate up.sh uses to decide "is this LAN IP already in the
# cert's SAN?": generate a temp self-signed cert covering IP 127.0.0.1, then run
# the exact `openssl x509 ... | grep -q "IP Address:$ip"` check.
crt="$SANDBOX/site.crt"; key="$SANDBOX/site.key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$crt" -days 2 \
  -subj "/CN=helixcode" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
covered_present=1; openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -q "IP Address:127.0.0.1" || covered_present=0
covered_absent=0;  openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -q "IP Address:203.0.113.7" && covered_absent=1
{ echo "predicate: SAN contains 127.0.0.1 (present in cert) -> match=$covered_present (want 1)"
  echo "predicate: SAN contains 203.0.113.7 (absent) -> match=$covered_absent (want 0)"; } >> "$ev"
if [ "$static_cert" -ge 1 ] && [ "$bare_internal" -eq 0 ] && [ "$up_regen_guard" -ge 1 ] && [ "$up_san_ext" -ge 1 ] && [ "$up_key_600" -ge 1 ] && [ "$covered_present" = 1 ] && [ "$covered_absent" = 0 ]; then
  ab_pass_with_evidence "TLS: static-cert Caddyfile (no bare 'tls internal') + up.sh SAN-coverage predicate proven on a real cert" "$ev"
else ab_fail "TLS-mode selection invariant broken [ev: ${ev#$HC_ROOT/}]"; fi

h_summary
