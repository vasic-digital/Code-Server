#!/usr/bin/env bash
#
# tests/test_inotify_watchers.sh
#
# Anti-bluff regression guard (§11.4.135) for the "unable to watch for file
# changes" (inotify ENOSPC) fix. Two layers:
#
#   A. Fix-artifact invariants — the watcherExclude settings, the sysctl
#      drop-in, and the compose/up.sh persistence+seed wiring are all present
#      and correct.
#   B. Deterministic RED->GREEN mechanism proof (§11.4.115) on a SYNTHETIC tree
#      (portable, no root, no huge real tree): with the shipped watcherExclude
#      dir-names applied, the watched-directory count stays UNDER a test limit;
#      without them it overflows. The exclude names are read from the shipped
#      settings.default.json, so the §1.1 paired mutation (strip a pattern)
#      makes the count cross the limit and this test FAIL.
#
# Polarity switch (§11.4.115):
#   RED_MODE=1  -> reproduce the defect: assert the UN-excluded count overflows.
#   RED_MODE=0  -> (default) assert the excluded count fits (the fix works).
#
# PASS -> "PASS: inotify watcher fix verified"  (exit 0)
# FAIL -> "FAIL: <reason>"                        (exit non-zero)
set -euo pipefail

if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$repo_root" ]; then
	cd "$repo_root"
else
	cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
fi

RED_MODE="${RED_MODE:-0}"
SETTINGS="deploy/code-server/settings.default.json"
SYSCTL="deploy/sysctl/99-helixcode-inotify.conf"
COMPOSE="deploy/compose.codeserver.yml"
UP="deploy/up.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- Layer A: fix-artifact invariants ------------------------------------
[ -f "$SETTINGS" ] || fail "missing $SETTINGS"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" \
	|| fail "$SETTINGS is not valid JSON"
python3 -c '
import json,sys
s=json.load(open(sys.argv[1]))
we=s.get("files.watcherExclude",{})
need=["**/.git/**","**/node_modules/**","**/build/**","**/out/**","**/target/**","**/prebuilts/**"]
missing=[p for p in need if not we.get(p)]
sys.exit("missing watcherExclude patterns: %s"%missing if missing else 0)
' "$SETTINGS" || fail "watcherExclude missing core patterns"

[ -f "$SYSCTL" ] || fail "missing $SYSCTL"
watches="$(awk -F= '/max_user_watches/{gsub(/[^0-9]/,"",$2); print $2}' "$SYSCTL")"
[ -n "$watches" ] && [ "$watches" -ge 1048576 ] \
	|| fail "$SYSCTL max_user_watches must be >= 1048576 (got '${watches:-unset}')"

grep -q 'cs-data:/home/coder/.local/share/code-server' "$UP" \
	|| fail "up.sh does not mount cs-data (settings would not persist)"
grep -q 'seeded code-server watcherExclude settings\|settings.default.json' "$UP" \
	|| fail "up.sh does not seed the default settings"
grep -qE '^\s*cs-data:' "$COMPOSE" || fail "compose does not declare the cs-data volume"

# ---- Layer B: deterministic RED->GREEN on a synthetic tree ----------------
# Read the exclude dir-names (from **/<name>/** patterns) actually shipped.
mapfile -t EX < <(python3 -c '
import json,sys,re
we=json.load(open(sys.argv[1])).get("files.watcherExclude",{})
seen=[]
for p,on in we.items():
    if not on: continue
    m=re.fullmatch(r"\*\*/(.+?)/\*\*",p)
    if m and "/" not in m.group(1): seen.append(m.group(1))
print("\n".join(seen))
' "$SETTINGS")
[ "${#EX[@]}" -ge 3 ] || fail "expected >=3 dir-name exclude patterns, got ${#EX[@]}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOISE_EACH=100; KEEP=50; TEST_LIMIT=120
# noise dirs use REAL shipped exclude names (.git, node_modules, build, ...)
for name in ".git" "node_modules" "build"; do
	for i in $(seq 1 "$NOISE_EACH"); do mkdir -p "$TMP/proj/$name/d$i"; done
done
for i in $(seq 1 "$KEEP"); do mkdir -p "$TMP/proj/src/keep$i"; done

# count_watched: dirs NOT under any shipped exclude name (GREEN) or ALL dirs (RED)
count_all() { find "$TMP" -type d | wc -l; }
count_excluded() {
	local args=() n
	for n in "${EX[@]}"; do args+=( -not -path "*/$n/*" -not -name "$n" ); done
	find "$TMP" -type d "${args[@]}" | wc -l
}

total="$(count_all)"; kept="$(count_excluded)"
echo "synthetic tree: total_dirs=$total  after_excludes=$kept  test_limit=$TEST_LIMIT  red_mode=$RED_MODE"

if [ "$RED_MODE" = "1" ]; then
	# Reproduce the defect: without excludes the watch count overflows the limit.
	[ "$total" -gt "$TEST_LIMIT" ] \
		|| fail "RED: expected total_dirs($total) > limit($TEST_LIMIT) — defect not reproduced"
	echo "RED reproduced: un-excluded watch count $total exceeds limit $TEST_LIMIT"
	echo "PASS: inotify watcher fix verified"; exit 0
fi

# GREEN: the fix keeps the watch count under the limit AND actually removes noise.
[ "$kept" -lt "$total" ] || fail "GREEN: excludes removed nothing ($kept == $total)"
[ "$kept" -le "$TEST_LIMIT" ] \
	|| fail "GREEN: watched dirs after excludes ($kept) exceed limit ($TEST_LIMIT) — a watcherExclude pattern is missing"
echo "GREEN: excluded watch count $kept fits under limit $TEST_LIMIT (down from $total)"
echo "PASS: inotify watcher fix verified"
