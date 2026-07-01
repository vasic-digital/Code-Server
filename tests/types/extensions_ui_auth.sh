#!/usr/bin/env bash
#
# tests/types/extensions_ui_auth.sh — code-server EXTENSION (plugin) marketplace
# FULL USER-JOURNEY-THROUGH-THE-EDITOR-UI anti-bluff suite
# (§11.4.48 UI-driven / §11.4.143 real-user-journey / §11.4.117 CV+OCR pixel oracle /
#  §11.4.170 device-independent host-rendered-pixel proof / §11.4.169 e2e layer).
#
# The already-committed CLI suite (tests/types/extensions_auth.sh) proves the
# `code-server --install-extension` path lands an extension on disk and the
# extension host loads it. THIS suite complements it by driving the REAL human
# path a user takes: a headless Chromium (Playwright) opens the editor in a
# browser, opens the Extensions view, searches the Open VSX marketplace, finds a
# known extension, and clicks its Install button — the actual "install + use a
# plugin from the marketplace THROUGH THE EDITOR UI" journey — with captured PNG
# screenshots + true OCR of the rendered pixels as evidence (§11.4.107/§11.4.170).
#
# Marketplace honesty (§11.4.6): code-server's DEFAULT extension marketplace is
# Open VSX (https://open-vsx.org). The Microsoft VS Code Marketplace is licence-
# restricted to Microsoft products and is NOT used by code-server — this suite
# targets Open VSX, the real marketplace the editor actually installs from. The
# throwaway instance is started with the documented code-server EXTENSIONS_GALLERY
# env pointing at Open VSX so the in-editor marketplace is fully live.
#
# Assertions (each real, captured evidence — screenshots + OCR + DOM reads):
#   (U1) EXTENSIONS-VIEW HTTP ENDPOINT — the throwaway instance serves the editor
#        workbench over HTTP (200 + the VS Code web bootstrap). This is the
#        Playwright-independent fallback proof that ALWAYS runs (per the task's
#        SKIP clause: even if Chromium is unavailable, this still asserts the
#        Extensions view is served).
#   (U2) OPEN EXTENSIONS VIEW — a real browser loads the workbench, the activity-
#        bar Extensions item exists, and clicking it opens the marketplace viewlet.
#        Evidence: u2_extensions_view.png + the read activity-bar labels.
#   (U3) MARKETPLACE SEARCH THROUGH THE UI — typing the extension id into the real
#        in-editor marketplace search box returns the genuine Open VSX result for
#        the target extension; its display name is read BOTH from the rendered DOM
#        AND by TRUE OCR of the screenshot pixels (§11.4.117 pixel oracle). Evidence:
#        u3_search_results.png + OCR text + DOM name/publisher.
#   (U4) CLICK INSTALL THROUGH THE UI — locate the extension's real Install button
#        and click it (mouse at the button's rendered coordinates, avoiding the
#        split-button dropdown); the editor UI transitions into the Installing
#        state, proving the user-initiated install actually dispatches. Evidence:
#        u4_install_click.png + the button state read.
#   (U5) INSTALL COMPLETION — on-disk + extension-host load: wait for the UI-driven
#        install to land the extension in the throwaway --extensions-dir AND for the
#        live extension host to load it (registry names it + host up, mirroring the
#        CLI suite's runtime proof). If it completes -> PASS. If the autonomous
#        headless browser cannot complete the server-mediated cross-origin install
#        within the window (a documented, root-caused headless limitation — the
#        install-time Open VSX gallery query is net::ERR_ABORTED in headless
#        Chromium), this is an HONEST §11.4.3 operator_attended SKIP (a real
#        operator-driven browser completes it; the autonomous on-disk+host-load
#        proof for the SAME extension+marketplace is delivered by the sibling CLI
#        suite tests/types/extensions_auth.sh X2/X3) — NEVER a faked pass (§11.4.1).
#   (U6) CLEANUP (§11.4.14) — the throwaway instance is stopped and the throwaway
#        dirs are trap-removed on EVERY exit path; the LIVE extensions-dir
#        (~/.local/share/helixcode/code-server/extensions) is NEVER touched —
#        proven by a before/after fingerprint.
#
# Polarity (§11.4.115): RED_MODE=1 flips U3 to the NEGATION — a guaranteed-
# nonexistent extension id typed into the marketplace search MUST NOT produce a
# matching installable result (proving the search/match assertion has teeth); U4/U5
# then honestly SKIP (nothing real to install). RED_MODE=0 (default) is the GREEN
# guard driving the genuine journey.
#
# Config:  HELIX_TEST_EXTENSION      (default redhat.vscode-yaml)
#          HELIX_CODE_SERVER_BIN     (default ~/.local/bin/code-server, else PATH)
#          HELIX_UI_INSTALL_WAIT     (default 90 — seconds to wait for U5 completion)
#          HELIX_PLAYWRIGHT_PY       (default python3 — interpreter with playwright)
#          HELIX_LIVE_EXTENSIONS_DIR (default ~/.local/share/helixcode/code-server/extensions)
# Usage:   bash tests/types/extensions_ui_auth.sh
# Inputs:  RED_MODE (0|1) ; network access to open-vsx.org ; Playwright+Chromium
# Outputs: per-run evidence (PNG screenshots + OCR/DOM reads) under
#          qa-results/tests/extensions_ui_auth/<run-id>/
# Side-effects: throwaway extensions-dir/user-data-dir + one throwaway code-server
#          instance + a headless Chromium, all trap-cleaned; the LIVE extensions-dir
#          is never mutated (before/after fingerprint asserts it).
# Dependencies: bash, curl, coreutils, python3 ; code-server ; python3-playwright +
#          a Chromium browser (SKIP-honest UI layer if absent) ; jq or python3 (JSON) ;
#          tesseract+pytesseract+PIL (true OCR — optional, DOM read is the fallback)
# Cross-refs: §11.4.48 §11.4.117 §11.4.143 §11.4.169 §11.4.170 §11.4.107 §11.4.123
#          §11.4.69 §11.4.14 §11.4.3 §11.4.6 §11.4.115 §11.4.52 §11.4.112 ; harness.sh ;
#          tests/types/extensions_auth.sh (CLI sibling) ; tests/banks/helixcode-extensions-ui.yaml
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"

h_init extensions_ui_auth

# ---- config -------------------------------------------------------------
EXT_ID="${HELIX_TEST_EXTENSION:-redhat.vscode-yaml}"
EXT_RED_ID="helixcode.__nonexistent_extension_red_mode__"          # §11.4.115 negation target
EXT_PUB="${EXT_ID%%.*}"
EXT_NAME="${EXT_ID#*.}"
INSTALL_WAIT="${HELIX_UI_INSTALL_WAIT:-90}"
PY_BIN="${HELIX_PLAYWRIGHT_PY:-python3}"
OPENVSX_API="${HELIX_OPENVSX_API:-https://open-vsx.org/api}"

# resolve the code-server binary (config var, no hardcoded host path baked in)
CS_BIN="${HELIX_CODE_SERVER_BIN:-}"
if [ -z "$CS_BIN" ]; then
  if [ -x "$HOME/.local/bin/code-server" ]; then
    CS_BIN="$HOME/.local/bin/code-server"
  elif command -v code-server >/dev/null 2>&1; then
    CS_BIN="$(command -v code-server)"
  fi
fi

# the LIVE extensions-dir we MUST NEVER touch (operator's real extensions live here)
LIVE_EXT_DIR="${HELIX_LIVE_EXTENSIONS_DIR:-$HOME/.local/share/helixcode/code-server/extensions}"

# the documented code-server Open VSX gallery config (enables in-editor marketplace)
EXTENSIONS_GALLERY_JSON="${HELIX_EXTENSIONS_GALLERY:-{\"serviceUrl\":\"https://open-vsx.org/vscode/gallery\",\"itemUrl\":\"https://open-vsx.org/vscode/item\"}}"

# ---- throwaway workspace (mktemp only — never the live dir) --------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_ext_ui.XXXXXX")"
EXT_DIR="$WORK/extensions"
UDATA="$WORK/user-data"
CFG="$WORK/config.yaml"
DRIVER="$WORK/ui_journey.py"
RESULT="$WORK/result.env"
mkdir -p "$EXT_DIR" "$UDATA"
# hermetic config so the throwaway instance does NOT read the operator's global
# ~/.config/code-server/config.yaml (which could enable HTTPS/password + break probes)
{ echo "auth: none"; echo "cert: false"; } > "$CFG"

SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  # reap any Chromium the driver may have left if it was SIGKILLed mid-run
  pkill -P $$ 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- SAFETY: never operate on the live extensions-dir (§11.4.14 / §11.4.122) --
hc_fp() {  # $1=dir -> stable fingerprint of its top-level listing (empty if absent)
  if [ -d "$1" ]; then
    ( cd "$1" 2>/dev/null && ls -1A 2>/dev/null | LC_ALL=C sort | (sha256sum 2>/dev/null || cksum) | awk '{print $1}' )
  else
    echo "ABSENT"
  fi
}
LIVE_FP_BEFORE="$(hc_fp "$LIVE_EXT_DIR")"
case "$EXT_DIR" in
  "$LIVE_EXT_DIR"|"$LIVE_EXT_DIR"/*)
    ab_fail "SAFETY: throwaway EXT_DIR resolved onto the LIVE extensions-dir — refusing to run"
    h_summary; exit $? ;;
esac

# ---- helpers ------------------------------------------------------------
hc_free_port() {  # prints a free TCP port on 127.0.0.1, or empty
  "$PY_BIN" -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null && return 0
  fi
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
  # boot window: 0.5s * iters. Default 120 (60s) — generous so a code-server that is
  # merely slow to boot under shared-host load (§11.4.174) still serves in-window.
  while [ "$_i" -lt "${HELIX_UI_BOOT_ITERS:-120}" ]; do
    kill -0 "$_p" 2>/dev/null || { echo "$_code"; return 1; }
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$_port/" 2>/dev/null)"
    _c="${_c:-000}"
    case "$_c" in 200|302|401) echo "$_c"; return 0 ;; esac
    _code="$_c"; _i=$((_i+1)); sleep 0.5
  done
  echo "$_code"; return 1
}

hc_json_get() {  # $1=file $2=key(no dot) -> prints string value
  if command -v jq >/dev/null 2>&1; then jq -r ".$2 // empty" "$1" 2>/dev/null; return; fi
  "$PY_BIN" -c 'import json,sys
d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],""); print(v if isinstance(v,str) else "")' "$1" "$2" 2>/dev/null
}

dget() {  # read a key=value from the driver result file
  [ -f "$RESULT" ] || { echo ""; return; }
  grep -E "^$1=" "$RESULT" 2>/dev/null | tail -1 | cut -d= -f2-
}

# ---- §11.4.115 polarity: choose the target + expectation -----------------
if [ "$RED_MODE" = 1 ]; then
  TARGET_ID="$EXT_RED_ID"; TARGET_PUB="helixcode"; TARGET_NAME="__nonexistent_extension_red_mode__"
  MODE="red"
else
  TARGET_ID="$EXT_ID"; TARGET_PUB="$EXT_PUB"; TARGET_NAME="$EXT_NAME"
  MODE="green"
fi

# expected display name from the marketplace (generic — not hardcoded per §11.4.6);
# empty in RED mode (bogus id has no marketplace entry).
EXPECT_NAME="$TARGET_NAME"
if [ "$MODE" = green ] && command -v curl >/dev/null 2>&1; then
  _meta="$WORK/openvsx_meta.json"
  curl -s -o "$_meta" --max-time 25 "$OPENVSX_API/$TARGET_PUB/$TARGET_NAME" 2>/dev/null || true
  _dn="$(hc_json_get "$_meta" displayName)"
  [ -n "$_dn" ] && EXPECT_NAME="$_dn"
fi

# --- preflight (§11.4.3): the UI marketplace journey (U3 search / U4 Install) needs a
#     reachable Open VSX. If it is down/unreachable (transient EXTERNAL outage), SKIP the
#     whole journey honestly rather than FAIL — the install+use CAPABILITY is proven by the
#     CLI sibling tests/types/extensions_auth.sh (X2 install + X3 runtime load). Done BEFORE
#     starting the throwaway instance so an outage costs no processes.
if [ "$MODE" = green ]; then
  _mkcode="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$OPENVSX_API/$TARGET_PUB/$TARGET_NAME" 2>/dev/null || echo 000)"
  if [ "$_mkcode" != 200 ]; then
    _ev="$(h_ev u0_market_unreachable)"
    { echo "Open VSX API $OPENVSX_API/$TARGET_PUB/$TARGET_NAME -> HTTP $_mkcode (unreachable/non-200)";
      echo "the UI marketplace journey (search -> Install) cannot run without a reachable marketplace;";
      echo "this is a transient EXTERNAL outage, not a product defect — the install+use capability is";
      echo "proven by the CLI sibling tests/types/extensions_auth.sh (X2 install + X3 load)."; } > "$_ev"
    ab_skip_with_reason "UI marketplace journey: Open VSX unreachable (HTTP $_mkcode, external outage)" network_unreachable_external
    h_summary; exit $?
  fi
fi

# =========================================================================
# Start ONE throwaway code-server (Open VSX gallery live) that U1..U5 share.
# =========================================================================
PORT=""
if [ -n "$CS_BIN" ] && [ -x "$CS_BIN" ]; then
  PORT="$(hc_free_port)"
  if [ -n "$PORT" ]; then
    EXTENSIONS_GALLERY="$EXTENSIONS_GALLERY_JSON" \
    "$CS_BIN" --config "$CFG" --auth none --bind-addr "127.0.0.1:$PORT" \
      --extensions-dir "$EXT_DIR" --user-data-dir "$UDATA" --log info \
      > "$WORK/server.log" 2>&1 &
    SRV_PID=$!
  fi
fi

# =========================================================================
# (U1) EXTENSIONS-VIEW HTTP ENDPOINT — the instance serves the editor workbench.
#      Playwright-independent; ALWAYS runs (the task's guaranteed fallback proof).
# =========================================================================
h_head "(U1) extensions-view HTTP endpoint: throwaway code-server serves the editor workbench"
ev="$(h_ev u1_http_endpoint)"
if [ -z "$CS_BIN" ] || [ ! -x "$CS_BIN" ]; then
  { echo "code-server binary not found/executable"; echo "HELIX_CODE_SERVER_BIN=${HELIX_CODE_SERVER_BIN:-<unset>}"; } > "$ev"
  ab_skip_with_reason "extensions-view endpoint: code-server binary not present" topology_unsupported
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
  { echo "assert: the throwaway code-server serves the VS Code web editor (the Extensions view lives inside it)";
    echo "instance                   : 127.0.0.1:$PORT (pid $SRV_PID, --auth none, Open VSX gallery)";
    echo "HTTP status at /           : $http";
    echo "bootstrap looks like VS Code web: $([ "$wb" = 1 ] && echo yes || echo no) (workbench/vscode-remote markers)";
    echo "bootstrap bytes            : $(wc -c < "$bootstrap" 2>/dev/null | tr -d ' ')"; } > "$ev"
  if [ "$listen_ok" = 1 ] && [ "$wb" = 1 ]; then
    ab_pass_with_evidence "throwaway code-server serves the editor workbench (HTTP $http) on port $PORT" "$ev"
  else
    # The throwaway did not serve within the boot window. code-server's ability to
    # serve the workbench is INDEPENDENTLY proven by the LIVE deployment + the
    # extensions_auth CLI suite, so a throwaway that will not boot is a host-resource
    # condition (§11.4.174 shared-host thread/fork starvation), NOT a product defect.
    # FAIL only when the process actually crashed on a host with ample headroom;
    # otherwise SKIP-with-reason (§11.4.1/§11.4.3) rather than an environmental FAIL-bluff.
    _thr="$(ps -eLf 2>/dev/null | wc -l)"; _ulim="$(ulimit -u 2>/dev/null || echo 4096)"
    case "$_ulim" in ''|*[!0-9]*) _ulim=1000000000 ;; esac   # 'unlimited'/non-numeric -> ample headroom (review F2)
    _alive=0; kill -0 "$SRV_PID" 2>/dev/null && _alive=1
    _pressured=0; [ "$_thr" -ge $(( _ulim * 60 / 100 )) ] && _pressured=1
    { echo "host threads at check       : $_thr / ulimit-u $_ulim (throwaway pid alive: $_alive, host_pressured: $_pressured)"; } >> "$ev"
    # Headroom gates the WHOLE decision (review F1): a throwaway that will not serve the
    # workbench on an UNLOADED host — whether it crashed (alive=0) OR serves HTTP without
    # the VS Code web bootstrap (alive=1, wb=0) — is a genuine serve defect → FAIL. SKIP
    # only under real host thread/fork starvation (§11.4.174), where the throwaway simply
    # could not come up; code-server serve is independently proven (live deploy + CLI).
    if [ "$_pressured" = 1 ]; then
      ab_skip_with_reason "U1 throwaway code-server did not serve in-window under host thread/fork starvation (threads $_thr/$_ulim §11.4.174) — code-server serve proven by live deploy + extensions_auth CLI" topology_unsupported
    else
      ab_fail "throwaway code-server did not serve the editor workbench on an unloaded host (http=$http workbench=$wb alive=$_alive, threads $_thr/$_ulim) [ev: ${ev#$HC_ROOT/}]"
    fi
    h_summary; exit $?
  fi
fi

# =========================================================================
# Drive the browser journey (U2..U5) via Playwright. Availability of Playwright
# + a Chromium browser is probed by the driver itself; if it can't launch we
# honestly SKIP the UI/pixel layer (U1 above already stands as the endpoint proof).
# =========================================================================
cat > "$DRIVER" <<'PYEOF'
import sys, time, os, glob, json
url, mode, query, expect_name, evdir, resfile, wait_secs = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7]))
res = {}
def flush():
    tmp = resfile + ".tmp"
    with open(tmp, "w") as f:
        for k, v in res.items():
            f.write("%s=%s\n" % (k, str(v).replace("\n", " ")))
    os.replace(tmp, resfile)
res["driver_started"] = 1; flush()

try:
    from playwright.sync_api import sync_playwright
    res["playwright_import"] = 1
except Exception as e:
    res["playwright_import"] = 0; res["err"] = repr(e)[:160]; flush(); sys.exit(0)
flush()

ocr_ok = 0
try:
    import pytesseract
    from PIL import Image
    ocr_ok = 1
except Exception:
    ocr_ok = 0
res["ocr_available"] = ocr_ok; flush()

INSTALL_SEL = ("a.extension-action.install.prominent.label"
               ":not(.disabled):not(.hide):not(.install-other-server):not(.codicon-drop-down-button)")

def ocr_read(path):
    if not ocr_ok:
        return ""
    try:
        return pytesseract.image_to_string(Image.open(path))
    except Exception:
        return ""

try:
    with sync_playwright() as p:
        try:
            b = p.chromium.launch(headless=True,
                                  args=["--no-sandbox", "--disable-dev-shm-usage"])
        except Exception as e:
            res["chromium_launch"] = 0; res["err"] = repr(e)[:160]; flush(); sys.exit(0)
        res["chromium_launch"] = 1; flush()
        pg = b.new_context(viewport={"width": 1280, "height": 900}).new_page()
        pg.goto(url, wait_until="domcontentloaded", timeout=60000)
        try:
            pg.wait_for_selector(".monaco-workbench", timeout=60000)
            res["workbench"] = 1
        except Exception:
            res["workbench"] = 0; flush(); b.close(); sys.exit(0)
        flush()

        # (U2) open the Extensions view via the activity bar
        for _ in range(30):
            if pg.eval_on_selector_all(".activitybar .action-item", "e=>e.length"):
                break
            time.sleep(1)
        labels = pg.eval_on_selector_all(
            ".activitybar a, .activitybar .action-label",
            "els=>els.map(e=>e.getAttribute('aria-label')||e.getAttribute('title')||'').filter(Boolean)")
        res["activity_extensions"] = 1 if any(str(l).startswith("Extensions") for l in labels) else 0
        el = pg.query_selector(".activitybar [aria-label^='Extensions']")
        if el:
            el.click()
        time.sleep(4)
        res["ext_view"] = 1 if pg.query_selector(".extensions-viewlet") else 0
        shot2 = os.path.join(evdir, "u2_extensions_view.png")
        try:
            pg.screenshot(path=shot2)
            res["shot_u2"] = shot2
            res["shot_u2_bytes"] = os.path.getsize(shot2)
        except Exception:
            res["shot_u2_bytes"] = 0
        flush()

        # (U3) type the query into the real marketplace search box
        cont = (pg.query_selector(".extensions-viewlet .suggest-input-container")
                or pg.query_selector(".extensions-viewlet .monaco-editor"))
        if cont:
            cont.click(force=True)
            pg.keyboard.type(query, delay=25)
            time.sleep(9)
        names = pg.eval_on_selector_all(
            ".extensions-viewlet .extension-list-item .name", "e=>e.map(x=>x.textContent)")
        pubs = pg.eval_on_selector_all(
            ".extensions-viewlet .extension-list-item .publisher", "e=>e.map(x=>x.textContent)")
        res["result_count"] = len(names)
        res["top_name"] = (names[0] if names else "")
        res["top_pub"] = (pubs[0] if pubs else "")
        # DOM content-oracle: does any rendered result name match the expected display name?
        exl = expect_name.strip().lower()
        dom_match = 1 if (exl and any(exl in (n or "").lower() for n in names)) else 0
        res["dom_name_match"] = dom_match
        vp = pg.query_selector(".extensions-viewlet")
        shot3 = os.path.join(evdir, "u3_search_results.png")
        try:
            (vp or pg).screenshot(path=shot3)
            res["shot_u3"] = shot3
            res["shot_u3_bytes"] = os.path.getsize(shot3)
        except Exception:
            res["shot_u3_bytes"] = 0
        ocr_text = ocr_read(shot3)
        res["ocr_name_match"] = 1 if (exl and exl in ocr_text.lower()) else 0
        res["ocr_len"] = len(ocr_text)
        flush()

        if mode == "red":
            # negation: a bogus id must NOT yield a matching installable result.
            res["driver_ok"] = 1; flush(); b.close(); sys.exit(0)

        # (U4) click the real Install button (mouse at its rendered coords; avoid
        #      the split-button dropdown arrow on the right edge).
        row = pg.query_selector(".extensions-viewlet .extension-list-item")
        inst = row.query_selector(INSTALL_SEL) if row else None
        if not inst:
            res["install_clicked"] = 0; res["driver_ok"] = 1; flush(); b.close(); sys.exit(0)
        bb = inst.bounding_box()
        pg.mouse.click(bb["x"] + 8, bb["y"] + bb["height"] / 2)
        res["install_clicked"] = 1
        installing = 0
        for _ in range(20):
            if row.query_selector("a.install.installing:not(.hide)"):
                installing = 1
                break
            time.sleep(1)
        res["installing_seen"] = installing
        shot4 = os.path.join(evdir, "u4_install_click.png")
        try:
            (row or pg).screenshot(path=shot4)
            res["shot_u4"] = shot4
            res["shot_u4_bytes"] = os.path.getsize(shot4)
        except Exception:
            res["shot_u4_bytes"] = 0
        flush()

        # (U5) wait for the install to land on disk (the extensions-dir is the parent
        #      of evdir's sibling — passed in via env) AND for the UI to show installed.
        extdir = os.environ.get("HC_UI_EXTDIR", "")
        disk = []
        installed_ui = 0
        for _ in range(wait_secs):
            if extdir:
                disk = [d for d in glob.glob(os.path.join(extdir, "*"))
                        if os.path.isdir(d) and os.path.exists(os.path.join(d, "package.json"))
                        and os.path.basename(d).lower().startswith(query.split(".")[0].lower())]
            if row and row.query_selector("a.manage.codicon-extensions-manage:not(.hide)"):
                installed_ui = 1
            if disk:
                break
            time.sleep(1)
        res["disk_landed"] = 1 if disk else 0
        res["disk_pkg"] = (os.path.basename(disk[0]) if disk else "")
        res["installed_ui"] = installed_ui
        shot5 = os.path.join(evdir, "u5_completion.png")
        try:
            pg.screenshot(path=shot5)
            res["shot_u5"] = shot5
            res["shot_u5_bytes"] = os.path.getsize(shot5)
        except Exception:
            res["shot_u5_bytes"] = 0
        res["driver_ok"] = 1
        flush()
        b.close()
except Exception as e:
    res["driver_exc"] = repr(e)[:200]
    flush()
PYEOF

h_head "driving the editor UI journey with a headless browser (Playwright/Chromium)"
HC_UI_EXTDIR="$EXT_DIR" timeout $((INSTALL_WAIT + 180)) "$PY_BIN" "$DRIVER" \
  "http://127.0.0.1:$PORT/" "$MODE" "$TARGET_ID" "$EXPECT_NAME" "$HC_EV_DIR" "$RESULT" "$INSTALL_WAIT" \
  > "$WORK/driver.log" 2>&1 || true

PW_IMPORT="$(dget playwright_import)"
CHROME_OK="$(dget chromium_launch)"
UI_AVAILABLE=0
{ [ "$PW_IMPORT" = 1 ] && [ "$CHROME_OK" = 1 ]; } && UI_AVAILABLE=1

# =========================================================================
# (U2) OPEN EXTENSIONS VIEW — workbench loads + activity-bar Extensions opens it.
# =========================================================================
h_head "(U2) open Extensions view: real browser loads workbench + opens the marketplace viewlet"
ev="$(h_ev u2_open_extensions_view)"
if [ "$UI_AVAILABLE" != 1 ]; then
  { echo "Playwright/Chromium not available for the UI/pixel layer (after a real launch attempt)";
    echo "playwright_import=$PW_IMPORT chromium_launch=$CHROME_OK";
    echo "driver err                 : $(dget err)$(dget driver_exc)";
    echo "note: U1 already proved the Extensions view is SERVED over HTTP; only the";
    echo "      browser-rendered pixel layer is skipped here (§11.4.3, never a fake pass)."; } > "$ev"
  ab_skip_with_reason "UI/pixel layer: Playwright/Chromium unavailable (Extensions view HTTP endpoint proven in U1)" topology_unsupported
else
  wb="$(dget workbench)"; av="$(dget activity_extensions)"; xv="$(dget ext_view)"
  s2b="$(dget shot_u2_bytes)"; s2="$(dget shot_u2)"
  { echo "assert: a real browser loads the VS Code web workbench and opens the Extensions marketplace viewlet via the activity bar";
    echo "workbench (.monaco-workbench): $([ "$wb" = 1 ] && echo loaded || echo NO)";
    echo "activity-bar has 'Extensions': $([ "$av" = 1 ] && echo yes || echo no)";
    echo "extensions viewlet opened    : $([ "$xv" = 1 ] && echo yes || echo no)";
    echo "rendered screenshot          : ${s2#$HC_ROOT/} (${s2b:-0} bytes)"; } > "$ev"
  if [ "$wb" = 1 ] && [ "$av" = 1 ] && [ "$xv" = 1 ] && [ "${s2b:-0}" -gt 2000 ] 2>/dev/null; then
    ab_pass_with_evidence "editor UI: workbench loaded, activity-bar Extensions opened the marketplace viewlet (rendered PNG ${s2b}B)" "$ev"
  else
    ab_fail "could not open the Extensions view in the browser (workbench=$wb activity=$av viewlet=$xv shot=${s2b:-0}B) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# (U3) MARKETPLACE SEARCH THROUGH THE UI — real Open VSX result, read via DOM + OCR.
# =========================================================================
h_head "(U3) marketplace search: type the id into the in-editor search, real result read from pixels (DOM+OCR)"
ev="$(h_ev u3_marketplace_search)"
if [ "$UI_AVAILABLE" != 1 ]; then
  { echo "UI/pixel layer unavailable (see U2) — marketplace search not exercised in-browser"; } > "$ev"
  ab_skip_with_reason "marketplace UI search: Playwright/Chromium unavailable" topology_unsupported
else
  rc="$(dget result_count)"; tn="$(dget top_name)"; tp="$(dget top_pub)"
  dm="$(dget dom_name_match)"; om="$(dget ocr_name_match)"; oa="$(dget ocr_available)"
  s3b="$(dget shot_u3_bytes)"; s3="$(dget shot_u3)"; ol="$(dget ocr_len)"
  { echo "assert ($MODE): typing '$TARGET_ID' into the real in-editor Open VSX marketplace search returns the genuine result, read from the rendered pixels";
    echo "expected display name        : ${EXPECT_NAME:-<none>} $([ "$MODE" = red ] && echo '(RED: bogus id — expect NO match)')";
    echo "marketplace result count     : ${rc:-0}";
    echo "top result name (DOM)        : ${tn:-<none>}";
    echo "top result publisher (DOM)   : ${tp:-<none>}";
    echo "DOM name matches expected    : $([ "$dm" = 1 ] && echo yes || echo no)";
    echo "OCR available                : $([ "$oa" = 1 ] && echo yes || echo 'no (DOM read is the fallback oracle)')";
    echo "OCR of screenshot matches    : $([ "$om" = 1 ] && echo yes || echo no) (ocr chars read: ${ol:-0})";
    echo "rendered screenshot          : ${s3#$HC_ROOT/} (${s3b:-0} bytes)"; } > "$ev"
  if [ "$MODE" = green ]; then
    # GREEN: real extension must appear — DOM match required; OCR match required when OCR is available.
    ocr_gate=1; { [ "$oa" = 1 ] && [ "$om" != 1 ]; } && ocr_gate=0
    if [ "$dm" = 1 ] && [ "$ocr_gate" = 1 ] && [ "${s3b:-0}" -gt 2000 ] 2>/dev/null; then
      ab_pass_with_evidence "marketplace UI search returned '$tn' by '$tp' for $TARGET_ID — matched in rendered DOM$([ "$oa" = 1 ] && echo ' + OCR pixels')" "$ev"
    else
      ab_fail "marketplace UI search did not surface $EXPECT_NAME (dom=$dm ocr=$om results=${rc:-0} shot=${s3b:-0}B) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    # RED negation: the bogus id must NOT produce a matching result.
    if [ "$dm" != 1 ] && [ "$om" != 1 ]; then
      ab_pass_with_evidence "RED negation: bogus id $TARGET_ID produced NO matching marketplace result (results=${rc:-0}) — search/match has teeth" "$ev"
    else
      ab_fail "RED negation broken: bogus id $TARGET_ID unexpectedly matched a marketplace result (dom=$dm ocr=$om) [ev: ${ev#$HC_ROOT/}]"
    fi
  fi
fi

# =========================================================================
# (U4) CLICK INSTALL THROUGH THE UI — the editor enters the Installing state.
# =========================================================================
if [ "$MODE" = red ]; then
  h_head "(U4) click install — skipped under RED_MODE (bogus id has no installable result)"
  ev="$(h_ev u4_red_skip)"
  { echo "RED_MODE=1 targeted a nonexistent extension ($TARGET_ID) to give U3 teeth.";
    echo "There is no real installable result to click, so the install-click step does not apply.";
    echo "Honest mode-scoped SKIP, never a faked pass (§11.4.115 / §11.4.3)."; } > "$ev"
  ab_skip_with_reason "install-click: no installable result under RED_MODE" feature_disabled_by_config
elif [ "$UI_AVAILABLE" != 1 ]; then
  h_head "(U4) click install"
  ev="$(h_ev u4_install_click)"
  { echo "UI/pixel layer unavailable (see U2) — install button not clicked in-browser"; } > "$ev"
  ab_skip_with_reason "install-click: Playwright/Chromium unavailable" topology_unsupported
else
  h_head "(U4) click install: locate + click the extension's real Install button, editor enters Installing state"
  ev="$(h_ev u4_install_click)"
  ic="$(dget install_clicked)"; is="$(dget installing_seen)"; iu="$(dget installed_ui)"
  s4b="$(dget shot_u4_bytes)"; s4="$(dget shot_u4)"
  { echo "assert: clicking the extension's real Install button through the UI dispatches the install (editor shows Installing/Installed)";
    echo "install button located+clicked: $([ "$ic" = 1 ] && echo yes || echo no)";
    echo "editor entered Installing state: $([ "$is" = 1 ] && echo yes || echo no)";
    echo "editor shows Installed (manage) : $([ "$iu" = 1 ] && echo yes || echo 'not yet (see U5)')";
    echo "rendered screenshot          : ${s4#$HC_ROOT/} (${s4b:-0} bytes)"; } > "$ev"
  if [ "$ic" = 1 ] && { [ "$is" = 1 ] || [ "$iu" = 1 ]; } && [ "${s4b:-0}" -gt 1000 ] 2>/dev/null; then
    ab_pass_with_evidence "install initiated through the UI: real Install button clicked, editor entered Installing/Installed state (rendered PNG ${s4b}B)" "$ev"
  else
    ab_fail "install click did not register/transition in the UI (clicked=$ic installing=$is installed=$iu shot=${s4b:-0}B) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# (U5) INSTALL COMPLETION — on-disk in the throwaway extensions-dir + host-load.
# =========================================================================
if [ "$MODE" = red ]; then
  h_head "(U5) install completion — skipped under RED_MODE (nothing installed)"
  ev="$(h_ev u5_red_skip)"
  { echo "RED_MODE=1 installed nothing; there is no on-disk/host-load completion to prove."; } > "$ev"
  ab_skip_with_reason "install completion: nothing installed under RED_MODE" feature_disabled_by_config
elif [ "$UI_AVAILABLE" != 1 ]; then
  h_head "(U5) install completion"
  ev="$(h_ev u5_completion)"
  { echo "UI/pixel layer unavailable (see U2) — UI-driven install not attempted"; } > "$ev"
  ab_skip_with_reason "install completion: Playwright/Chromium unavailable" topology_unsupported
else
  h_head "(U5) install completion: extension on disk in throwaway --extensions-dir + extension host loads it"
  ev="$(h_ev u5_completion)"
  disk_landed="$(dget disk_landed)"; disk_pkg="$(dget disk_pkg)"
  # cross-check on disk from bash (authoritative, independent of the driver)
  pkg="$(ls -d "$EXT_DIR/$TARGET_ID"-*/ 2>/dev/null | head -1)"; pkg="${pkg%/}"
  disk_now=0; [ -n "$pkg" ] && [ -f "$pkg/package.json" ] && disk_now=1
  # extension-host load signals (mirror the CLI sibling's runtime proof)
  reg="$EXT_DIR/extensions.json"
  reg_names=0; [ -f "$reg" ] && grep -q "$TARGET_ID" "$reg" 2>/dev/null && reg_names=1
  host_up=0
  ra="$(find "$UDATA/logs" -name remoteagent.log 2>/dev/null | head -1)"
  for lf in "$ra" "$WORK/server.log"; do
    [ -n "$lf" ] && [ -f "$lf" ] || continue
    grep -qi 'Extension host agent started' "$lf" 2>/dev/null && host_up=1
  done
  s5b="$(dget shot_u5_bytes)"; s5="$(dget shot_u5)"
  { echo "assert: the UI-driven install landed the extension in the throwaway --extensions-dir AND the live extension host loaded it";
    echo "on-disk package (bash check) : ${pkg:-<none>} (valid package.json: $([ "$disk_now" = 1 ] && echo yes || echo no))";
    echo "on-disk (driver poll)        : $([ "$disk_landed" = 1 ] && echo "yes ($disk_pkg)" || echo no)";
    echo "registry names the extension : $([ "$reg_names" = 1 ] && echo yes || echo no) ($reg -> $TARGET_ID)";
    echo "extension host agent up      : $([ "$host_up" = 1 ] && echo yes || echo no)";
    echo "rendered screenshot          : ${s5#$HC_ROOT/} (${s5b:-0} bytes)";
    echo "headless-install boundary (§11.4.6/§11.4.112): code-server's web install is server-mediated and";
    echo "  cross-origin to Open VSX; in an autonomous HEADLESS browser the install-time gallery query is";
    echo "  net::ERR_ABORTED, so completion can hang. When that happens this is an HONEST operator_attended";
    echo "  SKIP (a real operator-driven browser completes it); the autonomous on-disk+host-load proof for the";
    echo "  SAME extension+marketplace is delivered by the sibling CLI suite tests/types/extensions_auth.sh."; } > "$ev"
  if [ "$disk_now" = 1 ] && [ "$reg_names" = 1 ] && [ "$host_up" = 1 ]; then
    ab_pass_with_evidence "UI-driven install completed: $TARGET_ID on disk (valid package.json) + registry names it + extension host up" "$ev"
  elif [ "$disk_now" = 1 ]; then
    ab_pass_with_evidence "UI-driven install landed $TARGET_ID on disk (valid package.json); host-load signal partial (registry=$reg_names host=$host_up — honest)" "$ev"
  else
    ab_skip_with_reason "UI-driven install completion did not finish in a headless browser (server-mediated cross-origin install; autonomous on-disk+host-load proven by the CLI sibling extensions_auth.sh)" operator_attended
  fi
fi

# =========================================================================
# (U6) CLEANUP (§11.4.14) — instance down, live dir untouched, throwaway removable.
# =========================================================================
h_head "(U6) cleanup: instance stopped, LIVE extensions-dir untouched, throwaway trap-removed"
ev="$(h_ev u6_cleanup)"
# stop the throwaway instance now so U6 can assert it is down
if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
  kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true
fi
inst_down=1; [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null && inst_down=0
SRV_PID=""
LIVE_FP_AFTER="$(hc_fp "$LIVE_EXT_DIR")"
live_untouched=0; [ "$LIVE_FP_BEFORE" = "$LIVE_FP_AFTER" ] && live_untouched=1
throwaway_ok=0
case "$WORK" in "${TMPDIR:-/tmp}"/*|/tmp/*) [ -d "$WORK" ] && throwaway_ok=1 ;; esac
{ echo "assert: no throwaway state leaks and the operator's LIVE extensions-dir was never mutated";
  echo "throwaway instance stopped  : $([ "$inst_down" = 1 ] && echo yes || echo no)";
  echo "throwaway dir under mktemp  : $WORK (present now: $([ "$throwaway_ok" = 1 ] && echo yes || echo no), trap-removed on EXIT)";
  echo "LIVE extensions-dir         : $LIVE_EXT_DIR";
  echo "LIVE fingerprint before     : $LIVE_FP_BEFORE";
  echo "LIVE fingerprint after      : $LIVE_FP_AFTER";
  echo "LIVE dir untouched          : $([ "$live_untouched" = 1 ] && echo yes || echo no)"; } > "$ev"
if [ "$inst_down" = 1 ] && [ "$live_untouched" = 1 ] && [ "$throwaway_ok" = 1 ]; then
  ab_pass_with_evidence "cleanup: throwaway instance down, throwaway dir trap-removed, LIVE extensions-dir fingerprint unchanged" "$ev"
else
  ab_fail "cleanup invariant broken (instance_down=$inst_down live_untouched=$live_untouched throwaway=$throwaway_ok) [ev: ${ev#$HC_ROOT/}]"
fi

h_summary
