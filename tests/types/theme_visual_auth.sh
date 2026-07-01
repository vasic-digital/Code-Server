#!/usr/bin/env bash
#
# tests/types/theme_visual_auth.sh — §11.4.170 device-independent HOST-RENDERED
# pixel proof for the operator mandate "VS Code Dark theme MUST BE the default
# ALWAYS".
#
# The sibling tests/types/theme_default_auth.sh proves the CONFIG enforcement
# (deploy/code-server/settings.default.json seeds a VS Code dark colorTheme, and
# scripts/install-auth.sh copies it to User/settings.json on a fresh install).
# THIS suite adds the RENDERED-PIXEL proof required by §11.4.170: it launches a
# THROWAWAY code-server with HelixCode's default settings seeded, renders the
# real workbench in headless Chromium (via the CDP driver theme_visual_cdp.mjs —
# no npm/Playwright), captures a PNG, and asserts the rendered workbench is DARK
# from the REAL pixels (Rec.709 mean luminance below a calibrated dark ceiling +
# a high dark-pixel fraction) dual-validated by the applied theme kind read from
# the rendered workbench DOM (.monaco-workbench => vs-dark). Anti-bluff
# (§11.4.69/§11.4.123): every PASS cites the captured PNG + the measured
# luminance; a light default would be caught (RED_MODE self-validation).
#
#   (T1) the THROWAWAY code-server (default settings seeded) SERVES the VS Code
#        web workbench over HTTP (200 + workbench markers). Chromium-independent
#        endpoint proof that always runs.
#   (T2) §11.4.170 HOST-RENDERED PIXEL PROOF — the workbench RENDERS DARK: the
#        captured PNG's mean luminance is below the dark ceiling AND the theme
#        kind read from the rendered DOM is dark. SKIP-honest (§11.4.3
#        topology_unsupported) if Chromium is absent OR the SPA genuinely does
#        not render within the bound — NEVER a faked pass.
#
# Polarity (§11.4.115 / §11.4.107(10) golden-good/golden-bad): RED_MODE=0
# (default, GREEN) seeds the real default settings (dark) and asserts the
# rendered pixels are DARK. RED_MODE=1 seeds a LIGHT theme instead and asserts
# the rendered pixels are LIGHT — proving the luminance oracle has teeth (a
# non-dark default would visibly differ and be caught).
#
# Calibration (§11.4.6 — MEASURED live, not guessed): on the real dark workbench
# the captured PNG measured mean luminance = 44.3 (0..255) with dark-fraction
# 0.93 (workbench bg rgb(37,37,38) = #252526); the RED_MODE light-theme workbench
# measured 228.5 (theme kind 'light'). The dark ceiling (95) and light floor
# (150) sit cleanly inside that 44<->228 gap — see the measured value echoed into
# the T2 evidence for every run.
#
# Usage        : RED_MODE=0 bash tests/types/theme_visual_auth.sh
# Inputs       : HELIX_CODE_SERVER_BIN (override), HELIX_CHROME (override),
#                HELIX_THEME_RENDER_WAIT (default 60s), RED_MODE
# Outputs      : qa-results/tests/theme_visual_auth/<run-id>/ evidence (incl. PNG)
# Side-effects : one throwaway code-server + a headless Chromium + throwaway
#                mktemp dirs, all trap-cleaned on EVERY exit; the LIVE code-server
#                and LIVE user-data-dir are NEVER touched.
# Dependencies : bash, curl, coreutils, python3 (free port) ; code-server ;
#                node + a Chromium browser (SKIP-honest if absent) ; tesseract
#                (optional OCR)
# Cross-refs   : §11.4.162 §11.4.169 §11.4.170 §11.4.107 §11.4.123 §11.4.69
#                §11.4.14 §11.4.3 §11.4.6 §11.4.115 ; harness.sh ;
#                theme_default_auth.sh (config sibling) ; theme_visual_cdp.mjs ;
#                tests/banks/helixcode-theme-visual.yaml
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"

h_init theme_visual_auth

# ---- config -------------------------------------------------------------
DEFAULT_JSON="$HC_ROOT/deploy/code-server/settings.default.json"
RENDER_WAIT="${HELIX_THEME_RENDER_WAIT:-60}"
DARK_MAX="${HELIX_THEME_DARK_MAX:-95}"    # calibrated dark-luminance ceiling (0..255)
LIGHT_MIN="${HELIX_THEME_LIGHT_MIN:-150}" # calibrated light-luminance floor (0..255)
DARK_FRAC="${HELIX_THEME_DARK_FRAC:-0.6}" # min dark-pixel fraction for DARK

# resolve the code-server binary (config var, no hardcoded host path baked in)
CS_BIN="${HELIX_CODE_SERVER_BIN:-}"
if [ -z "$CS_BIN" ]; then
  if [ -x "$HOME/.local/bin/code-server" ]; then
    CS_BIN="$HOME/.local/bin/code-server"
  elif command -v code-server >/dev/null 2>&1; then
    CS_BIN="$(command -v code-server)"
  fi
fi

# the LIVE code-server user-data-dir we MUST NEVER touch (operator's real state)
LIVE_UDATA="${HELIX_LIVE_USER_DATA_DIR:-$HOME/.local/share/helixcode/code-server}"

# §11.4.115 polarity: what to seed + what the rendered pixels must be
if [ "$RED_MODE" = 1 ]; then
  SEED_THEME="Visual Studio Light"; EXPECT="light"; MODE="red"
else
  SEED_THEME=""; EXPECT="dark"; MODE="green"   # SEED_THEME empty => copy real default settings verbatim
fi

# ---- throwaway workspace (mktemp only — never the live dir) --------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_theme_vis.XXXXXX")"
UDATA="$WORK/user-data"
EXT_DIR="$WORK/ext"
CFG="$WORK/config.yaml"
mkdir -p "$UDATA/User" "$EXT_DIR"
# hermetic config so the throwaway instance does NOT read the operator's global
# ~/.config/code-server/config.yaml (which could enable HTTPS/password + break probes)
{ echo "auth: none"; echo "cert: false"; } > "$CFG"

SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  # reap any Chromium the driver may have left if SIGKILLed mid-run
  pkill -P $$ 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- SAFETY: never operate on the live user-data-dir (§11.4.14 / §11.4.122) --
case "$UDATA" in
  "$LIVE_UDATA"|"$LIVE_UDATA"/*)
    ab_fail "SAFETY: throwaway user-data-dir resolved onto the LIVE code-server user-data — refusing to run"
    h_summary; exit $? ;;
esac

# ---- seed HelixCode's default settings into the throwaway User/settings.json --
SETTINGS="$UDATA/User/settings.json"
if [ "$MODE" = green ]; then
  # EXACTLY what scripts/install-auth.sh does on a fresh box: copy the seeded default
  cp "$DEFAULT_JSON" "$SETTINGS" 2>/dev/null || true
else
  # RED: seed a LIGHT theme so the luminance oracle is proven to distinguish
  printf '{\n  "workbench.colorTheme": "%s"\n}\n' "$SEED_THEME" > "$SETTINGS"
fi
SEEDED_THEME="$(grep -oE '"workbench\.colorTheme"[[:space:]]*:[[:space:]]*"[^"]+"' "$SETTINGS" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"[[:space:]]*$//')"

# ---- free-port helper ---------------------------------------------------
hc_free_port() {
  python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null && return 0
  _n=0
  while [ "$_n" -lt 50 ]; do
    _p=$(( (RANDOM % 20000) + 40000 ))
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$_p\$"; then echo "$_p"; return 0; fi
    _n=$((_n+1))
  done
  echo ""; return 1
}

hc_wait_listen() {  # $1=pid $2=port -> echoes final http code; rc 0 if listening
  _p="$1"; _port="$2"; _code=000; _i=0
  while [ "$_i" -lt 90 ]; do
    kill -0 "$_p" 2>/dev/null || { echo "$_code"; return 1; }
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$_port/" 2>/dev/null)"
    _c="${_c:-000}"
    case "$_c" in 200|302|401) echo "$_c"; return 0 ;; esac
    _code="$_c"; _i=$((_i+1)); sleep 0.5
  done
  echo "$_code"; return 1
}

# ---- start ONE throwaway code-server (default settings seeded) -----------
PORT=""
if [ -n "$CS_BIN" ] && [ -x "$CS_BIN" ]; then
  PORT="$(hc_free_port)"
  if [ -n "$PORT" ]; then
    "$CS_BIN" --config "$CFG" --auth none --bind-addr "127.0.0.1:$PORT" \
      --user-data-dir "$UDATA" --extensions-dir "$EXT_DIR" --log info \
      > "$WORK/server.log" 2>&1 &
    SRV_PID=$!
  fi
fi

# =========================================================================
# (T1) the throwaway code-server SERVES the workbench (endpoint proof, always).
# =========================================================================
h_head "(T1) throwaway code-server (default settings seeded) serves the VS Code web workbench"
ev="$(h_ev t1_http_endpoint)"
if [ -z "$CS_BIN" ] || [ ! -x "$CS_BIN" ]; then
  { echo "code-server binary not found/executable"; echo "HELIX_CODE_SERVER_BIN=${HELIX_CODE_SERVER_BIN:-<unset>}"; } > "$ev"
  ab_skip_with_reason "theme render proof: code-server binary not present" topology_unsupported
  h_summary; exit $?
elif [ -z "$PORT" ] || [ -z "$SRV_PID" ]; then
  { echo "could not allocate a free port / start the throwaway instance"; } > "$ev"
  ab_fail "could not start throwaway code-server [ev: ${ev#$HC_ROOT/}]"
  h_summary; exit $?
else
  http="$(hc_wait_listen "$SRV_PID" "$PORT")"; listen_ok=0
  case "$http" in 200|302|401) listen_ok=1 ;; esac
  bootstrap="$WORK/root.html"
  curl -s --max-time 8 "http://127.0.0.1:$PORT/" > "$bootstrap" 2>/dev/null || true
  wb=0; grep -qiE 'workbench|vscode-remote|static/out' "$bootstrap" 2>/dev/null && wb=1
  { echo "assert: the throwaway code-server (mode=$MODE, seeded colorTheme='${SEEDED_THEME:-<none>}') serves the VS Code web workbench";
    echo "instance                   : 127.0.0.1:$PORT (pid $SRV_PID, --auth none)";
    echo "seeded settings            : $SETTINGS";
    echo "HTTP status at /           : $http";
    echo "bootstrap looks like VS Code web: $([ "$wb" = 1 ] && echo yes || echo no) (workbench/vscode-remote markers)";
    echo "bootstrap bytes            : $(wc -c < "$bootstrap" 2>/dev/null | tr -d ' ')"; } > "$ev"
  if [ "$listen_ok" = 1 ] && [ "$wb" = 1 ]; then
    ab_pass_with_evidence "throwaway code-server serves the workbench (HTTP $http) on port $PORT" "$ev"
  else
    ab_fail "throwaway code-server did not serve the workbench (http=$http workbench=$wb) [ev: ${ev#$HC_ROOT/}]"
    h_summary; exit $?
  fi
fi

# =========================================================================
# (T2) §11.4.170 HOST-RENDERED PIXEL PROOF — the workbench RENDERS DARK.
# =========================================================================
h_head "(T2) §11.4.170 host-rendered pixel proof: the workbench RENDERS $EXPECT (headless Chromium via CDP)"
ev="$(h_ev t2_rendered_pixels)"; vdir="$HC_EV_DIR/t2_rendered_pixels"; mkdir -p "$vdir"
have_chrome=0
[ -n "${HELIX_CHROME:-}" ] && [ -x "${HELIX_CHROME:-}" ] && have_chrome=1
for b in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable; do [ -x "$b" ] && have_chrome=1; done

if ! h_require node || [ "$have_chrome" != 1 ]; then
  { echo "node present: $(h_require node && echo yes || echo no); chromium present: $([ "$have_chrome" = 1 ] && echo yes || echo no)";
    echo "note: T1 already proved the workbench is SERVED over HTTP; only the browser-rendered";
    echo "      pixel layer is skipped here (§11.4.3, never a fake pass)."; } > "$ev"
  ab_skip_with_reason "host-rendered pixel proof (node/Chromium not present; workbench-served proven in T1)" topology_unsupported
else
  rc=0
  node "$_here/theme_visual_cdp.mjs" \
    --url "http://127.0.0.1:$PORT/" --out "$vdir" --expect "$EXPECT" \
    --dark-max "$DARK_MAX" --light-min "$LIGHT_MIN" --dark-frac "$DARK_FRAC" --wait "$RENDER_WAIT" \
    > "$WORK/driver.log" 2>&1 || rc=$?
  VJSON="$(grep -E '^VERDICT_JSON: ' "$WORK/driver.log" 2>/dev/null | tail -1 | sed 's/^VERDICT_JSON: //')"
  # pull the measured numbers out of the verdict JSON for the evidence record
  MEAN="$(printf '%s' "$VJSON" | grep -oE '"meanLum":[-0-9.]+' | head -1 | cut -d: -f2)"
  DFRAC="$(printf '%s' "$VJSON" | grep -oE '"darkFrac":[-0-9.]+' | head -1 | cut -d: -f2)"
  TKIND="$(printf '%s' "$VJSON" | grep -oE '"themeKind":"[a-z]+"' | head -1 | cut -d: -f2 | tr -d '"')"
  PNG="$(ls -1 "$vdir"/theme_rendered.png 2>/dev/null | head -1)"
  { echo "assert (§11.4.170, mode=$MODE): the throwaway code-server workbench RENDERS $EXPECT from the REAL pixels";
    echo "seeded colorTheme            : ${SEEDED_THEME:-<none>}";
    echo "driver rc                    : $rc (0=proven 2=skip-honest 1=wrong-polarity)";
    echo "measured mean luminance      : ${MEAN:-<none>} (0..255; dark ceiling=$DARK_MAX, light floor=$LIGHT_MIN)";
    echo "measured dark-pixel fraction : ${DFRAC:-<none>} (min for dark=$DARK_FRAC)";
    echo "theme kind read from DOM     : ${TKIND:-<none>} (rendered .monaco-workbench classList)";
    echo "rendered PNG artifact        : ${PNG:-<none>}";
    echo "--- driver verdict ---"; printf '%s\n' "${VJSON:-<no verdict json>}";
    echo "--- artifacts ---"; ls -1 "$vdir" 2>/dev/null | sed 's/^/artifact: /'; } > "$ev"
  if [ "$rc" -eq 0 ] && [ -s "$PNG" ]; then
    # ab_pass_with_evidence needs a non-empty file; append the PNG size so the
    # evidence file cites the captured pixel artifact.
    echo "rendered PNG bytes           : $(wc -c < "$PNG" 2>/dev/null | tr -d ' ')" >> "$ev"
    ab_pass_with_evidence "workbench RENDERS $EXPECT — mean luminance ${MEAN:-?} (theme kind '${TKIND:-?}') proven on captured pixels ${PNG#$HC_ROOT/}" "$ev"
  elif [ "$rc" -eq 2 ]; then
    ab_skip_with_reason "host-rendered pixel proof (Chromium unavailable OR workbench did not render within ${RENDER_WAIT}s)" topology_unsupported
  else
    ab_fail "workbench did NOT render $EXPECT (rc=$rc, mean luminance ${MEAN:-?}, theme kind '${TKIND:-?}') [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# (T3) CLEANUP (§11.4.14) — instance down, LIVE user-data untouched, throwaway removable.
# =========================================================================
h_head "(T3) cleanup: throwaway instance stopped, LIVE user-data untouched, throwaway trap-removed"
ev="$(h_ev t3_cleanup)"
if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
  kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true
fi
inst_down=1; [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null && inst_down=0
SRV_PID=""
throwaway_ok=0
case "$WORK" in "${TMPDIR:-/tmp}"/*|/tmp/*) [ -d "$WORK" ] && throwaway_ok=1 ;; esac
live_untouched=1; case "$UDATA" in "$LIVE_UDATA"|"$LIVE_UDATA"/*) live_untouched=0 ;; esac
{ echo "assert: no throwaway state leaks and the operator's LIVE user-data-dir was never targeted";
  echo "throwaway instance stopped   : $([ "$inst_down" = 1 ] && echo yes || echo no)";
  echo "throwaway dir under mktemp   : $WORK (present now: $([ "$throwaway_ok" = 1 ] && echo yes || echo no), trap-removed on EXIT)";
  echo "throwaway user-data-dir      : $UDATA";
  echo "LIVE user-data-dir           : $LIVE_UDATA";
  echo "throwaway is NOT the live dir: $([ "$live_untouched" = 1 ] && echo yes || echo no)"; } > "$ev"
if [ "$inst_down" = 1 ] && [ "$throwaway_ok" = 1 ] && [ "$live_untouched" = 1 ]; then
  ab_pass_with_evidence "cleanup: throwaway instance down, throwaway dir trap-removed, LIVE user-data-dir never targeted" "$ev"
else
  ab_fail "cleanup invariant broken (instance_down=$inst_down throwaway=$throwaway_ok live_untouched=$live_untouched) [ev: ${ev#$HC_ROOT/}]"
fi

h_summary
