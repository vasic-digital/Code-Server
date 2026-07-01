#!/usr/bin/env bash
#
# scripts/show-extension-gallery.sh — PRINT the extension (plugin) marketplace
# gallery code-server is currently configured to use. READ-ONLY: it inspects the
# EXTENSIONS_GALLERY environment variable and the bundled VS Code product.json and
# reports what it finds. It NEVER writes, installs, uninstalls, switches the
# gallery, or touches the Microsoft VS Code Marketplace.
#
# Purpose      : Answer "which extension gallery does HelixCode's code-server use?"
#                with rock-solid, on-host evidence (§11.4.6 no-guessing) — the
#                default is Open VSX (open-vsx.org); the MS Marketplace is licence-
#                restricted and NOT used (see docs/guides/EXTENSIONS.md).
# Usage        : scripts/show-extension-gallery.sh
#                HELIX_CODE_SERVER_PRODUCT_JSON=/path/to/product.json \
#                  scripts/show-extension-gallery.sh      # explicit product.json
# Inputs       : env EXTENSIONS_GALLERY (optional; VS Code gallery JSON blob)
#                env HELIX_CODE_SERVER_PRODUCT_JSON (optional; override search)
# Outputs      : human-readable report on stdout; exit 0 always on a clean run
#                (this is an informational probe, not a gate).
# Side-effects : NONE (read-only). No files written, no gallery changed.
# Dependencies : POSIX sh/coreutils; optional jq OR python3 for JSON parsing
#                (falls back to a grep-based reader / honest "install jq" note).
# Cross-refs   : docs/guides/EXTENSIONS.md ; docs/scripts/show-extension-gallery.md ;
#                deploy/systemd/helix-code-server.service ;
#                tests/types/extensions_auth.sh ; §11.4.6 §11.4.10 §11.4.18 §11.4.78
#
# Parseable under bash AND POSIX sh (§11.4.67): no bash-only constructs.

set -u

# Open VSX is code-server's built-in default gallery (compiled into the dist and
# documented by Eclipse "Using Open VSX in VS Code"). Printed when nothing else
# overrides it. These are public endpoints, not secrets.
DEFAULT_SERVICE_URL="https://open-vsx.org/vscode/gallery"
DEFAULT_ITEM_URL="https://open-vsx.org/vscode/item"

# ---- tiny JSON readers (optional tools; honest fallback) -----------------
# read a top-level-ish key from a JSON *string* on stdin -> prints value or empty
json_str_get() {  # $1 = jq path (e.g. .serviceUrl) ; reads JSON from stdin
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // empty" 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    _key=$(printf '%s' "$1" | sed 's/^\.//')
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
v=d.get(sys.argv[1],"")
print(v if isinstance(v,str) else "")' "$_key" 2>/dev/null
    return 0
  fi
  # last-resort grep: pull the first "key":"value" match
  grep -oE "\"${1#.}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" 2>/dev/null \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

# read .extensionsGallery from a product.json FILE -> prints the raw value
# ("null" when absent) using jq/python; empty when no tool available.
product_gallery_raw() {  # $1 = product.json path
  if command -v jq >/dev/null 2>&1; then
    jq -c '.extensionsGallery // "null"' "$1" 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
g=d.get("extensionsGallery")
print("null" if g is None else json.dumps(g))' "$1" 2>/dev/null
    return 0
  fi
  echo ""   # no JSON tool
}

# ---- resolve the bundled product.json (no version hard-coded) ------------
resolve_product_json() {
  if [ -n "${HELIX_CODE_SERVER_PRODUCT_JSON:-}" ]; then
    [ -f "$HELIX_CODE_SERVER_PRODUCT_JSON" ] && { printf '%s\n' "$HELIX_CODE_SERVER_PRODUCT_JSON"; return 0; }
  fi
  # common install locations; last matching glob entry wins (highest version)
  _found=""
  for _pat in \
    "$HOME"/.local/lib/code-server-*/lib/vscode/product.json \
    /usr/lib/code-server/lib/vscode/product.json \
    /usr/local/lib/code-server/lib/vscode/product.json \
    "$HOME"/.local/share/code-server/lib/vscode/product.json
  do
    [ -f "$_pat" ] && _found="$_pat"
  done
  printf '%s\n' "$_found"
}

# ---- report --------------------------------------------------------------
echo "HelixCode — configured extension (plugin) gallery"
echo "================================================="
echo "(read-only probe; see docs/guides/EXTENSIONS.md)"
echo

# (1) EXTENSIONS_GALLERY environment override (highest precedence) ----------
echo "[1] EXTENSIONS_GALLERY env var:"
if [ -n "${EXTENSIONS_GALLERY:-}" ]; then
  _svc=$(printf '%s' "$EXTENSIONS_GALLERY" | json_str_get .serviceUrl)
  _itm=$(printf '%s' "$EXTENSIONS_GALLERY" | json_str_get .itemUrl)
  if [ -n "$_svc" ] || [ -n "$_itm" ]; then
    echo "    SET (overrides product.json + built-in default)"
    echo "      serviceUrl : ${_svc:-<unparsed>}"
    echo "      itemUrl    : ${_itm:-<unparsed>}"
  else
    echo "    SET, but could not parse serviceUrl/itemUrl"
    echo "      (install jq or python3 to show the parsed URLs)"
  fi
  GALLERY_SOURCE="EXTENSIONS_GALLERY env var"
else
  echo "    not set"
fi
echo

# (2) product.json extensionsGallery ---------------------------------------
PJ=$(resolve_product_json)
echo "[2] product.json extensionsGallery:"
if [ -z "$PJ" ]; then
  echo "    product.json not found (set HELIX_CODE_SERVER_PRODUCT_JSON to point at it)"
else
  echo "    file: $PJ"
  _raw=$(product_gallery_raw "$PJ")
  if [ -z "$_raw" ]; then
    echo "    value: <unknown — install jq or python3 to read it>"
  elif [ "$_raw" = "null" ] || [ "$_raw" = "\"null\"" ]; then
    echo "    value: null  (no gallery hard-coded here)"
  else
    echo "    value: $_raw"
    [ -z "${GALLERY_SOURCE:-}" ] && GALLERY_SOURCE="product.json extensionsGallery"
  fi
fi
echo

# (3) effective gallery ----------------------------------------------------
echo "[3] Effective gallery:"
if [ -n "${EXTENSIONS_GALLERY:-}" ]; then
  echo "    -> from the EXTENSIONS_GALLERY env var (see [1])"
elif [ -n "${GALLERY_SOURCE:-}" ]; then
  echo "    -> from product.json (see [2])"
else
  echo "    -> code-server BUILT-IN DEFAULT: Open VSX (open-vsx.org)"
  echo "         serviceUrl : $DEFAULT_SERVICE_URL"
  echo "         itemUrl    : $DEFAULT_ITEM_URL"
fi
echo
echo "Note: code-server's default marketplace is Open VSX, an open-source registry"
echo "operated by the Eclipse Foundation. The Microsoft VS Code Marketplace is"
echo "licence-restricted to Microsoft products and is NOT used by code-server."
echo "This tool never switches the gallery. To change it, see EXTENSIONS.md §3."

exit 0
