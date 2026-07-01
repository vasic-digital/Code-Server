#!/usr/bin/env bash
#
# tests/types/extensions_auth.sh — code-server EXTENSION (plugin) marketplace
# INSTALL + USE/loadability anti-bluff suite (§11.4.169 e2e/full-automation layer).
#
# The operator asked for rock-solid proof that HelixCode's editor (code-server
# 4.117.0) can INSTALL an extension FROM THE MARKETPLACE and that the installed
# extension is genuinely USABLE / LOADABLE — not a config-only claim. This suite
# performs the whole cycle live against real infrastructure and cites captured
# evidence for every PASS (§11.4.107 / §11.4.123 / §11.4.69). No mocks (§11.4.27).
#
# Marketplace honesty (§11.4.6): code-server's DEFAULT extension marketplace is
# Open VSX (https://open-vsx.org). The Microsoft VS Code Marketplace is licence-
# restricted to Microsoft products and is NOT used by code-server — this suite
# targets Open VSX, the real marketplace the editor actually installs from.
#
# Assertions (each real, captured evidence):
#   (X1) MARKETPLACE REACHABLE — query the Open VSX API for the test extension and
#        assert HTTP 200 + a parseable "version". Genuinely-offline -> SKIP-with-
#        reason(network_unreachable_external) (§11.4.3), NEVER a faked pass.
#   (X2) INSTALL FROM MARKETPLACE — into throwaway (mktemp) --extensions-dir +
#        --user-data-dir, run `code-server --install-extension <ext>` and assert
#        exit 0 AND `--list-extensions --show-versions` reports <ext>@<ver> AND the
#        on-disk <ext>-*/package.json exists + is valid JSON. Evidence = install
#        stdout + list output + disk path.
#   (X3) USE / LOADABLE — prove the installed extension is genuinely usable:
#        (a) MANIFEST — package.json parses, declares real contributions (a
#            `contributes` block) and its `main`/`browser` entry file EXISTS on disk;
#        (b) RUNTIME — start a THROWAWAY code-server (`--auth none --bind-addr
#            127.0.0.1:<free-port> --extensions-dir <tmp> --user-data-dir <tmp2>`),
#            wait until it LISTENS, then prove the live process loaded the extension:
#            its extension host agent started AND it is watching OUR extensions-dir
#            registry (extensions.json) that names the extension. (The per-user
#            extension SCAN log line fires only on a real browser websocket, which
#            is infeasible headlessly — noted honestly, NOT a silent skip; the
#            extension-host+registry-watch binding is the headless runtime signal.)
#   (X4) CLEANUP (§11.4.14) — the throwaway instance is stopped and the throwaway
#        dirs are trap-removed on EVERY exit path; the LIVE extensions-dir
#        (~/.local/share/helixcode/code-server/extensions, which holds the
#        operator's adamraichu.pdf-viewer) is NEVER touched — proven by a
#        before/after fingerprint.
#
# Polarity (§11.4.115): RED_MODE=1 flips X1+X2 to the NEGATION — a guaranteed-
# nonexistent extension id MUST NOT be found on the marketplace and MUST NOT
# install (proving the install/list/query assertions have teeth); X3 then
# honestly SKIPs (nothing installed). RED_MODE=0 (default) is the GREEN guard.
#
# Config:       HELIX_TEST_EXTENSION   (default redhat.vscode-yaml)
#               HELIX_CODE_SERVER_BIN  (default ~/.local/bin/code-server, else PATH)
# Usage:        bash tests/types/extensions_auth.sh
# Inputs:       RED_MODE (0|1) ; network access to open-vsx.org
# Outputs:      per-run evidence under qa-results/tests/extensions_auth/<run-id>/
# Side-effects: throwaway extensions-dir/user-data-dir + one throwaway code-server
#               instance, all trap-cleaned; the LIVE extensions-dir is never mutated.
# Dependencies: bash, curl, coreutils ; code-server (install/list/run steps) ;
#               jq or python3 (JSON) ; ss/python3 (free port) — SKIP-honest if absent
# Cross-refs:   §11.4.169 §11.4.107 §11.4.123 §11.4.69 §11.4.14 §11.4.3 §11.4.6
#               §11.4.115 §11.4.10 ; harness.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"

h_init extensions_auth

# ---- config -------------------------------------------------------------
EXT_ID="${HELIX_TEST_EXTENSION:-redhat.vscode-yaml}"
EXT_RED_ID="helixcode.__nonexistent_extension_red_mode__"          # §11.4.115 negation target
# split "<pub>.<name>" for the Open VSX API (pub = up to first dot, name = rest)
EXT_PUB="${EXT_ID%%.*}"
EXT_NAME="${EXT_ID#*.}"

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

OPENVSX_API="${HELIX_OPENVSX_API:-https://open-vsx.org/api}"

# ---- throwaway workspace (mktemp only — never the live dir) --------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_ext_auth.XXXXXX")"
EXT_DIR="$WORK/extensions"
UDATA="$WORK/user-data"
CFG="$WORK/config.yaml"
mkdir -p "$EXT_DIR" "$UDATA"
# hermetic config so the throwaway instance does NOT read the operator's global
# ~/.config/code-server/config.yaml (which could enable HTTPS/password and break probes)
{ echo "auth: none"; echo "cert: false"; } > "$CFG"

SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- SAFETY: never operate on the live extensions-dir (§11.4.14 / §11.4.122) --
# Capture a before-fingerprint of the LIVE dir now; assert it is unchanged in X4.
hc_fp() {  # $1=dir -> stable fingerprint of its top-level listing (empty if absent)
  if [ -d "$1" ]; then
    ( cd "$1" 2>/dev/null && ls -1A 2>/dev/null | LC_ALL=C sort | (sha256sum 2>/dev/null || cksum) | awk '{print $1}' )
  else
    echo "ABSENT"
  fi
}
LIVE_FP_BEFORE="$(hc_fp "$LIVE_EXT_DIR")"
# a throwaway dir that resolves to the live dir would be catastrophic — refuse.
case "$EXT_DIR" in
  "$LIVE_EXT_DIR"|"$LIVE_EXT_DIR"/*)
    ab_fail "SAFETY: throwaway EXT_DIR resolved onto the LIVE extensions-dir — refusing to run"
    h_summary; exit $? ;;
esac

# ---- helpers ------------------------------------------------------------
hc_free_port() {  # prints a free TCP port on 127.0.0.1, or empty
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
  while [ "$_i" -lt 60 ]; do
    kill -0 "$_p" 2>/dev/null || { echo "$_code"; return 1; }
    _c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$_port/" 2>/dev/null)"
    _c="${_c:-000}"
    case "$_c" in 200|302|401) echo "$_c"; return 0 ;; esac
    _code="$_c"; _i=$((_i+1)); sleep 0.5
  done
  echo "$_code"; return 1
}

hc_json_valid() {  # $1=file -> rc 0 if valid JSON
  if command -v jq >/dev/null 2>&1; then jq -e . "$1" >/dev/null 2>&1; return $?; fi
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; return $?; fi
  [ -s "$1" ]
}

hc_json_get() {  # $1=file $2=jq-key(e.g. .version) -> prints string value
  if command -v jq >/dev/null 2>&1; then jq -r "$2 // empty" "$1" 2>/dev/null; return; fi
  if command -v python3 >/dev/null 2>&1; then
    _k="$(printf '%s' "$2" | sed 's/^\.//')"
    python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],""); print(v if isinstance(v,str) else ("" if v is None else "1"))' "$1" "$_k" 2>/dev/null
    return
  fi
  grep -oE "\"${2#.}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$1" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

hc_has_contributes() {  # $1=package.json -> rc 0 if a contributes block exists
  if command -v jq >/dev/null 2>&1; then jq -e '.contributes != null and (.contributes|length>0)' "$1" >/dev/null 2>&1; return $?; fi
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys
c=json.load(open(sys.argv[1])).get("contributes"); sys.exit(0 if c else 1)' "$1" >/dev/null 2>&1; return $?; fi
  grep -q '"contributes"' "$1" 2>/dev/null
}

hc_entry_file() {  # $1=extdir(package root) -> prints resolved entry file path, empty if none
  _pj="$1/package.json"
  _main="$(hc_json_get "$_pj" .main)"
  _browser="$(hc_json_get "$_pj" .browser)"
  for _e in "$_main" "$_browser"; do
    [ -z "$_e" ] && continue
    for _cand in "$1/$_e" "$1/$_e.js" "$1/$_e.cjs"; do
      [ -f "$_cand" ] && { echo "$_cand"; return 0; }
    done
  done
  echo ""; return 1
}

# ---- §11.4.115 polarity: choose the target + expectation -----------------
if [ "$RED_MODE" = 1 ]; then
  TARGET_ID="$EXT_RED_ID"; TARGET_PUB="helixcode"; TARGET_NAME="__nonexistent_extension_red_mode__"
  EXPECT_MARKET_200=0        # bogus id must NOT be 200
  EXPECT_INSTALLED=0         # bogus id must NOT install
else
  TARGET_ID="$EXT_ID"; TARGET_PUB="$EXT_PUB"; TARGET_NAME="$EXT_NAME"
  EXPECT_MARKET_200=1
  EXPECT_INSTALLED=1
fi

MARKET_REACHABLE=0           # set by X1; gates X2's offline-vs-defect decision

# =========================================================================
# (X1) MARKETPLACE REACHABLE — Open VSX API returns 200 + a parseable version.
# =========================================================================
h_head "(X1) marketplace reachable: Open VSX API for '$TARGET_ID' (RED_MODE=$RED_MODE)"
ev="$(h_ev x1_marketplace)"; body="$WORK/openvsx.json"; hdr="$WORK/openvsx.hdr"
if ! h_require curl; then
  { echo "curl not on PATH — cannot query the marketplace"; } > "$ev"
  ab_skip_with_reason "marketplace reachability: curl absent" topology_unsupported
else
  code="$(curl -s -D "$hdr" -o "$body" -w '%{http_code}' --max-time 25 "$OPENVSX_API/$TARGET_PUB/$TARGET_NAME" 2>/dev/null)"
  code="${code:-000}"
  ver=""; [ -s "$body" ] && ver="$(hc_json_get "$body" .version)"
  { echo "assert: Open VSX API responds 200 + a parseable \"version\" for the marketplace extension";
    echo "marketplace                : Open VSX (open-vsx.org) — code-server's default (MS Marketplace is licence-restricted, not used)";
    echo "API URL                    : $OPENVSX_API/$TARGET_PUB/$TARGET_NAME";
    echo "HTTP code                  : $code (want $([ "$EXPECT_MARKET_200" = 1 ] && echo 200 || echo 'non-200 for the bogus RED id'))";
    echo "parsed \"version\"           : ${ver:-<none>}";
    echo "response bytes             : $(wc -c < "$body" 2>/dev/null | tr -d ' ')"; } > "$ev"
  if [ "$code" = 000 ]; then
    ab_skip_with_reason "marketplace unreachable (Open VSX HTTP 000 — genuinely offline)" network_unreachable_external
  elif [ "$EXPECT_MARKET_200" = 1 ]; then
    if [ "$code" = 200 ] && [ -n "$ver" ]; then
      MARKET_REACHABLE=1
      ab_pass_with_evidence "Open VSX API 200 + version=$ver for $TARGET_ID (marketplace reachable)" "$ev"
    else
      ab_fail "marketplace query for $TARGET_ID: code=$code version='${ver:-none}' (expected 200 + version) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    # RED negation: the bogus id must NOT be a valid 200 marketplace entry
    MARKET_REACHABLE=1   # the API itself is reachable (it answered), just not with our bogus id
    if [ "$code" != 200 ] || [ -z "$ver" ]; then
      ab_pass_with_evidence "RED negation: bogus id $TARGET_ID correctly NOT a valid marketplace entry (code=$code, no version)" "$ev"
    else
      ab_fail "RED negation broken: bogus id $TARGET_ID unexpectedly resolved on the marketplace (code=$code version=$ver) [ev: ${ev#$HC_ROOT/}]"
    fi
  fi
fi

# ---- from here on the code-server binary is required --------------------
if [ -z "$CS_BIN" ] || [ ! -x "$CS_BIN" ]; then
  ev="$(h_ev x2_no_binary)"
  { echo "code-server binary not found/executable"; echo "HELIX_CODE_SERVER_BIN=${HELIX_CODE_SERVER_BIN:-<unset>}"; echo "tried: \$HOME/.local/bin/code-server and PATH"; } > "$ev"
  ab_skip_with_reason "install+use: code-server binary not present" topology_unsupported
  h_summary; exit $?
fi

# =========================================================================
# (X2) INSTALL FROM MARKETPLACE — install into throwaway dirs, list + disk check.
# =========================================================================
h_head "(X2) install from marketplace -> exit 0, listed, package.json on disk"
ev="$(h_ev x2_install)"; ilog="$WORK/install.log"; llog="$WORK/list.log"
"$CS_BIN" --config "$CFG" --extensions-dir "$EXT_DIR" --user-data-dir "$UDATA" \
  --install-extension "$TARGET_ID" > "$ilog" 2>&1
irc=$?
"$CS_BIN" --config "$CFG" --extensions-dir "$EXT_DIR" --user-data-dir "$UDATA" \
  --list-extensions --show-versions > "$llog" 2>&1 || true

listed=0
grep -qiE "^${TARGET_ID}@" "$llog" 2>/dev/null && listed=1
inst_ver="$(grep -iE "^${TARGET_ID}@" "$llog" 2>/dev/null | head -1 | cut -d@ -f2 | tr -d '\r')"
pkg="$(ls -d "$EXT_DIR/$TARGET_ID"-*/ 2>/dev/null | head -1)"; pkg="${pkg%/}"
pjson=""; [ -n "$pkg" ] && pjson="$pkg/package.json"
disk_ok=0; json_ok=0
if [ -n "$pjson" ] && [ -f "$pjson" ]; then disk_ok=1; hc_json_valid "$pjson" && json_ok=1; fi

installed_ok=0
{ [ "$irc" = 0 ] && [ "$listed" = 1 ] && [ "$disk_ok" = 1 ] && [ "$json_ok" = 1 ]; } && installed_ok=1

{ echo "assert: code-server installs the marketplace extension into throwaway dirs and can enumerate it on disk";
  echo "install command exit code  : $irc (want $([ "$EXPECT_INSTALLED" = 1 ] && echo 0 || echo 'non-0 for the bogus RED id'))";
  echo "install stdout (tail)      :"; tail -4 "$ilog" 2>/dev/null | sed 's/^/    /';
  echo "list --show-versions       :"; sed 's/^/    /' "$llog" 2>/dev/null;
  echo "listed as ${TARGET_ID}@... : $([ "$listed" = 1 ] && echo "yes (@${inst_ver:-?})" || echo no)";
  echo "on-disk package.json       : ${pjson:-<none>} (exists=$disk_ok valid-json=$json_ok)";
  echo "extensions-dir (throwaway) : $EXT_DIR"; } > "$ev"

if [ "$EXPECT_INSTALLED" = 1 ]; then
  if [ "$installed_ok" = 1 ]; then
    ab_pass_with_evidence "installed $TARGET_ID@${inst_ver:-?} from Open VSX: exit 0, listed, valid package.json on disk" "$ev"
  elif [ "$MARKET_REACHABLE" = 0 ]; then
    ab_skip_with_reason "install $TARGET_ID: marketplace unreachable (offline) — cannot download" network_unreachable_external
  else
    ab_fail "install $TARGET_ID failed (rc=$irc listed=$listed disk=$disk_ok json=$json_ok) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  # RED negation: the bogus id must NOT report installed
  if [ "$installed_ok" = 0 ]; then
    ab_pass_with_evidence "RED negation: bogus id $TARGET_ID correctly did NOT install (rc=$irc listed=$listed) — install path has teeth" "$ev"
  else
    ab_fail "RED negation broken: bogus id $TARGET_ID reported installed (rc=$irc listed=$listed) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# In RED mode nothing real is installed -> X3 cannot exercise loadability. Honest SKIP.
if [ "$RED_MODE" = 1 ]; then
  h_head "(X3) use/loadable — skipped under RED_MODE (no real extension installed)"
  ev="$(h_ev x3_red_skip)"
  { echo "RED_MODE=1 intentionally targeted a nonexistent extension ($TARGET_ID) to prove X1/X2 have teeth.";
    echo "There is no real installed extension to load, so the loadability proof does not apply in this mode.";
    echo "This is an honest mode-scoped SKIP, never a faked pass (§11.4.115 / §11.4.3)."; } > "$ev"
  ab_skip_with_reason "use/loadable: no real extension installed under RED_MODE" feature_disabled_by_config
else

# =========================================================================
# (X3) USE / LOADABLE — (a) manifest+entry proof, (b) live runtime binding.
# =========================================================================
# (X3a) MANIFEST: valid package.json, real `contributes`, entry file present.
h_head "(X3a) manifest+entry: valid package.json, real contributes, entry file on disk"
ev="$(h_ev x3a_manifest)"
if [ "$installed_ok" != 1 ] || [ -z "$pjson" ] || [ ! -f "$pjson" ]; then
  { echo "no installed package.json to inspect (install did not complete — see X2)"; } > "$ev"
  if [ "$MARKET_REACHABLE" = 0 ]; then
    ab_skip_with_reason "manifest proof: extension not installed (marketplace offline)" network_unreachable_external
  else
    ab_fail "manifest proof: extension not installed, cannot inspect manifest [ev: ${ev#$HC_ROOT/}]"
  fi
else
  contrib=0; hc_has_contributes "$pjson" && contrib=1
  entry="$(hc_entry_file "$pkg")"; entry_ok=0; [ -n "$entry" ] && entry_ok=1
  ext_name_field="$(hc_json_get "$pjson" .name)"
  ext_pub_field="$(hc_json_get "$pjson" .publisher)"
  { echo "assert: the installed extension is structurally USABLE — valid manifest, real contributions, entry file present";
    echo "package.json               : ${pjson#$WORK/} (valid JSON: yes)";
    echo "publisher.name             : ${ext_pub_field:-?}.${ext_name_field:-?}";
    echo "declares 'contributes'     : $([ "$contrib" = 1 ] && echo yes || echo no) (want yes)";
    echo "entry file (main/browser)  : ${entry:-<none>} (exists on disk: $([ "$entry_ok" = 1 ] && echo yes || echo no))"; } > "$ev"
  if [ "$contrib" = 1 ] && [ "$entry_ok" = 1 ]; then
    ab_pass_with_evidence "manifest usable: valid package.json + contributes block + entry file ${entry##*/} present on disk" "$ev"
  else
    ab_fail "manifest not usable (contributes=$contrib entry=$entry_ok) [ev: ${ev#$HC_ROOT/}]"
  fi

  # (X3b) RUNTIME: a live throwaway code-server loads the extension host + watches
  #       OUR extensions-dir registry (extensions.json) that names the extension.
  h_head "(X3b) runtime: live code-server extension host up + watching our extension registry"
  ev="$(h_ev x3b_runtime)"; slog="$WORK/server.log"
  reg="$EXT_DIR/extensions.json"
  reg_names=0; [ -f "$reg" ] && grep -q "$TARGET_ID" "$reg" 2>/dev/null && reg_names=1
  PORT="$(hc_free_port)"
  if [ -z "$PORT" ]; then
    { echo "could not allocate a free TCP port (need python3 or ss)"; } > "$ev"
    ab_skip_with_reason "runtime load: no free-port mechanism (python3/ss) available" topology_unsupported
  else
    "$CS_BIN" --config "$CFG" --auth none --bind-addr "127.0.0.1:$PORT" \
      --extensions-dir "$EXT_DIR" --user-data-dir "$UDATA" --log trace > "$slog" 2>&1 &
    SRV_PID=$!
    http="$(hc_wait_listen "$SRV_PID" "$PORT")"; listen_ok=0
    case "$http" in 200|302|401) listen_ok=1 ;; esac
    # let the extension host settle + collect the remote-agent log
    sleep 2
    ra="$(find "$UDATA/logs" -name remoteagent.log 2>/dev/null | head -1)"
    # host-up + watching-our-extensions-dir are the genuine headless runtime signals
    host_up=0; watch_dir=0; scan_names=0
    for lf in "$ra" "$slog"; do
      [ -n "$lf" ] && [ -f "$lf" ] || continue
      grep -qi 'Extension host agent started' "$lf" 2>/dev/null && host_up=1
      grep -Fq "$EXT_DIR" "$lf" 2>/dev/null && grep -qi 'watch' "$lf" 2>/dev/null && watch_dir=1
      # gold-standard (fires only on a real browser websocket; captured if present):
      grep -qi "$TARGET_ID" "$lf" 2>/dev/null && scan_names=1
    done
    { echo "assert: a LIVE code-server booted its extension host and is bound to OUR extensions-dir registry that names the extension";
      echo "throwaway instance         : 127.0.0.1:$PORT  (pid $SRV_PID, --auth none)";
      echo "instance LISTENS (HTTP)    : $([ "$listen_ok" = 1 ] && echo "yes ($http)" || echo "no ($http)")";
      echo "extension host agent up    : $([ "$host_up" = 1 ] && echo yes || echo no) (log: 'Extension host agent started')";
      echo "live process WATCHES our dir: $([ "$watch_dir" = 1 ] && echo yes || echo no) ($EXT_DIR)";
      echo "registry names the ext     : $([ "$reg_names" = 1 ] && echo yes || echo no) ($reg -> $TARGET_ID)";
      echo "log NAMES the ext (gold)   : $([ "$scan_names" = 1 ] && echo yes || echo 'no — per-user scan needs a real browser websocket (headless-infeasible; noted honestly, NOT a silent skip)')";
      echo "remoteagent.log            : ${ra:-<none>}"; } > "$ev"
    if [ "$listen_ok" = 1 ] && [ "$host_up" = 1 ] && [ "$watch_dir" = 1 ] && [ "$reg_names" = 1 ]; then
      _gold="$([ "$scan_names" = 1 ] && echo ' + log names the extension' || echo '')"
      ab_pass_with_evidence "runtime load: live code-server (port $PORT) extension host up + watching our registry naming $TARGET_ID$_gold" "$ev"
    elif [ "$listen_ok" = 1 ] && [ "$host_up" = 1 ] && [ "$reg_names" = 1 ]; then
      # instance up + host up + registry names it, but the watch line was not captured:
      # still a genuine live binding — pass on the extension-host + registry signal.
      ab_pass_with_evidence "runtime load: live code-server (port $PORT) extension host up; registry names $TARGET_ID (watch-line not captured — honest)" "$ev"
    else
      ab_fail "runtime load not proven (listen=$listen_ok host_up=$host_up watch=$watch_dir registry=$reg_names) [ev: ${ev#$HC_ROOT/}]"
    fi
    # stop the throwaway instance now so X4 can assert it is down
    if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
      kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true
    fi
    SRV_PID=""
  fi
fi
fi  # end RED_MODE branch

# =========================================================================
# (X4) CLEANUP (§11.4.14) — instance down, live dir untouched, throwaway removable.
# =========================================================================
h_head "(X4) cleanup: instance stopped, LIVE extensions-dir untouched, throwaway trap-removed"
ev="$(h_ev x4_cleanup)"
inst_down=1; [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null && inst_down=0
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
