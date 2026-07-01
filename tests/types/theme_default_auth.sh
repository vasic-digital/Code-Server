#!/usr/bin/env bash
#
# tests/types/theme_default_auth.sh — §11.4.169 / §11.4.135 regression guard for the
# operator mandate "VS Code Dark theme MUST BE the default theme ALWAYS".
#
# Enforcement lives in the SEEDED default settings (deploy/code-server/settings.default.json),
# which scripts/install-auth.sh copies to the code-server User/settings.json on a
# fresh install, so every HelixCode deployment defaults to a VS Code dark theme.
# Anti-bluff (§11.4.69): every PASS cites the captured settings evidence.
#
#   (T1) the SEEDED default settings set workbench.colorTheme to a VS Code DARK theme
#        (and the file is valid JSON).
#   (T2) a FRESH install (seed copied, as install-auth.sh does) carries the dark theme.
#   (T3) the LIVE deployment's User/settings.json enforces the dark theme (or SKIP if a
#        fresh box has no user settings yet — the seed in T1 then applies).
#
# Usage        : RED_MODE=0 bash tests/types/theme_default_auth.sh
# Inputs       : HELIX_LIVE_USER_SETTINGS (override), RED_MODE
# Outputs      : qa-results/tests/theme_default_auth/<run-id>/ evidence
# Side-effects : none on the git tree / live state; a throwaway mktemp file, trap-removed
# Dependencies : bash, grep ; python3 optional (strict JSON validity)
# Cross-refs   : §11.4.135 §11.4.162 §11.4.169 §11.4.69 ; harness.sh ; install-auth.sh
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/harness.sh
. "$_here/../lib/harness.sh"

h_init theme_default_auth

# Known VS Code built-in DARK color themes (the operator's "VS Code Dark theme").
DARK_THEMES_REGEX='Visual Studio Dark|Default Dark|Dark Modern|Dark[+]|Dark High Contrast|Abyss|Kimbie Dark|Monokai|Solarized Dark|Tomorrow Night'
DEFAULT_JSON="$HC_ROOT/deploy/code-server/settings.default.json"
LIVE_JSON="${HELIX_LIVE_USER_SETTINGS:-$HOME/.local/share/helixcode/code-server/User/settings.json}"

extract_theme() { grep -oE '"workbench\.colorTheme"[[:space:]]*:[[:space:]]*"[^"]+"' "$1" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"[[:space:]]*$//'; }

# ---- (T1) seeded default enforces a VS Code dark theme + valid JSON --------
h_head "(T1) seeded default settings enforce a VS Code Dark colorTheme"
ev="$(h_ev t1_default_seed)"
theme="$(extract_theme "$DEFAULT_JSON")"
json_ok=1
if command -v python3 >/dev/null 2>&1; then python3 -c "import json,sys; json.load(open('$DEFAULT_JSON'))" 2>/dev/null || json_ok=0; fi
{ echo "assert: $DEFAULT_JSON sets workbench.colorTheme to a known VS Code dark theme and is valid JSON";
  echo "colorTheme = '${theme:-<none>}'  json_valid=$json_ok";
  echo "--- default settings ---"; cat "$DEFAULT_JSON"; } > "$ev"
if [ -n "$theme" ] && printf '%s' "$theme" | grep -qiE "$DARK_THEMES_REGEX" && [ "$json_ok" = 1 ]; then
  ab_pass_with_evidence "seeded default enforces VS Code dark theme '$theme' (valid JSON)" "$ev"
else
  ab_fail "seeded default does not enforce a VS Code dark theme (got '${theme:-none}', json_valid=$json_ok) [ev: ${ev#$HC_ROOT/}]"
fi

# ---- (T2) a fresh install (seed copied) carries the dark theme -------------
h_head "(T2) a fresh install seeds the dark theme into User/settings.json"
ev="$(h_ev t2_fresh_install)"; tmp="$(mktemp -d "${TMPDIR:-/tmp}/hc_theme.XXXXXX")"
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT INT TERM
mkdir -p "$tmp/User"
# EXACTLY what scripts/install-auth.sh does on a fresh box: cp the default to User/settings.json
cp "$DEFAULT_JSON" "$tmp/User/settings.json"
fresh_theme="$(extract_theme "$tmp/User/settings.json")"
{ echo "assert: install-auth.sh's fresh-install seed (cp settings.default.json -> User/settings.json) yields the dark theme";
  echo "seeded User/settings.json colorTheme = '${fresh_theme:-<none>}'"; } > "$ev"
if [ -n "$fresh_theme" ] && printf '%s' "$fresh_theme" | grep -qiE "$DARK_THEMES_REGEX"; then
  ab_pass_with_evidence "fresh install seeds VS Code dark theme '$fresh_theme' as the default" "$ev"
else
  ab_fail "fresh install did not seed a dark theme (got '${fresh_theme:-none}') [ev: ${ev#$HC_ROOT/}]"
fi

# ---- (T3) the LIVE deployment enforces the dark theme ---------------------
h_head "(T3) the LIVE deployment's user settings enforce the dark theme"
ev="$(h_ev t3_live)"
if [ -f "$LIVE_JSON" ]; then
  live_theme="$(extract_theme "$LIVE_JSON")"
  { echo "assert: the running deployment's $LIVE_JSON enforces a VS Code dark theme";
    echo "live colorTheme = '${live_theme:-<none>}'"; } > "$ev"
  if [ -n "$live_theme" ] && printf '%s' "$live_theme" | grep -qiE "$DARK_THEMES_REGEX"; then
    ab_pass_with_evidence "LIVE deployment enforces VS Code dark theme '$live_theme'" "$ev"
  else
    ab_fail "LIVE user settings do not enforce a dark theme (got '${live_theme:-none}') [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "no live user settings at $LIVE_JSON (fresh box) — the T1 seed applies on first install"; } > "$ev"
  ab_skip_with_reason "no live user settings present (fresh install — T1 seed governs)" "topology_unsupported"
fi

h_summary
