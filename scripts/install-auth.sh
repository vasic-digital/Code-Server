#!/usr/bin/env bash
# scripts/install-auth.sh — install the host-native real-account editor + ssh-key gate.
#
# Purpose:      Wire up the host-native side of the real-account code-server model
#               with SSH-KEY challenge-response login (spec
#               docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md):
#               (1) install code-server from the pinned standalone GitHub-release
#               tarball into a user-writable prefix (~/.local/lib) + symlink it
#               onto ~/.local/bin (PRIMARY, no sudo; npm global is the documented
#               fallback — the tarball avoids the npm registry version-lag +
#               corrupted-tarball/ENOENT failures seen on this host);
#               (2) build the helix-auth gate binary from services/auth_gate/ into
#               ~/.local/bin (pure Go, no cgo — it execs ssh-keygen) when that
#               service source exists; (3) install + enable the two systemd --user
#               unit templates (helix-code-server, helix-auth) with deploy/.env
#               values substituted. Everything runs NON-root: no sudo, no
#               /etc/pam.d, no root daemon — the gate verifies an ssh signature
#               against the account's own authorized_keys. Idempotent: safe to re-run.
# Usage:        scripts/install-auth.sh            (install/refresh the units)
#               scripts/install-auth.sh -h|--help  (show this header)
#               CODE_SERVER_VERSION=4.117.0 scripts/install-auth.sh  (pin version)
# Inputs:       deploy/.env — HELIX_AUTH_ACCOUNT, HELIX_AUTH_MODE (sshkey),
#               HELIX_AUTH_PRINCIPAL, HELIX_AUTH_AUTHORIZED_KEYS, PROJECTS_ROOT.
#               deploy/systemd/*.service (the unit templates).
#               services/auth_gate/ (Go source for the helix-auth binary, if present).
#               Env: CODE_SERVER_VERSION (default 4.117.0).
# Outputs:      code-server on PATH (~/.local/bin/code-server symlink ->
#               ~/.local/lib/code-server-<ver>-linux-amd64/bin/code-server, or the
#               npm-global bin on fallback); helix-auth at ~/.local/bin (when
#               services/auth_gate/ is present); rendered units at
#               ~/.config/systemd/user/{helix-code-server,helix-auth}.service;
#               enabled (+ started where the binary is present) --user services.
# Side-effects: downloads + extracts the code-server standalone tarball into
#               ~/.local/lib and symlinks it onto ~/.local/bin if absent (npm
#               global `npm i -g code-server@<ver>` only as documented fallback);
#               `go build` of the gate into user-writable ~/.local/bin if source
#               present; writes the two --user unit files; `systemctl --user
#               daemon-reload` + enable/start of ONLY those two units; ensures
#               own-user linger; seeds code-server watcherExclude defaults if absent.
#               NEVER touches/stops/kills any process, container, or unit not named
#               helix-code-server / helix-auth (§11.4.174). NEVER runs sudo/root.
# Dependencies: bash; curl or wget + tar (tarball install); npm (Node.js — only
#               for the fallback); go (for the gate build); systemd (--user,
#               linger); ssh-keygen (used by the gate at runtime); scripts/lib.sh.
# Cross-references: docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md,
#               deploy/systemd/*.service, deploy/up.sh, deploy/.env.example, §11.4.18.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --help prints the leading §11.4.18 doc block (comment lines from line 2 on).
case "${1:-}" in
	-h|--help) awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print;next} exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

# Unit names we are ALLOWED to manage — §11.4.174 forbids touching anything else
# on this shared host (letsencrypt-caddy, helix_proxy, lava-*, proxy-* etc.).
CS_UNIT="helix-code-server.service"
AUTH_UNIT="helix-auth.service"

TEMPLATE_DIR="$HC_DEPLOY/systemd"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# code-server version pin. Installed PRIMARY from the pinned standalone GitHub-
# release tarball (code-server-<ver>-linux-amd64.tar.gz), with `npm i -g` as the
# documented fallback. The tarball is the robust path on this host: it sidesteps
# the npm-registry version lag (4.118–4.126 ship as GitHub releases/tarballs but
# are NOT published to npm, so `npm i -g code-server@4.126.0` fails E404) AND the
# corrupted-tarball/ENOENT npm failures observed here — the working install was in
# fact done from the standalone tarball. 4.117.0 is patched against CVE-2025-47269
# (fixed >=4.99.4) and also happens to be the newest npm-published version, so the
# npm fallback still resolves it. Re-pin to the newest tarball release at review
# (2026-08-01). Override: CODE_SERVER_VERSION=…
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.117.0}"
BIN_DIR="$HOME/.local/bin"
CS_ARCH="linux-amd64"                    # this deployment is x86_64 (§11.4.6 FACT).
CS_LIB_DIR="$HOME/.local/lib"            # user-writable prefix for the extracted tree.
AUTH_GATE_SRC="$HC_ROOT/services/auth_gate"

# --- code-server standalone-tarball install (PRIMARY; NON-root) --------------
# cs_download <url> <out> — fetch a URL to a file with curl (retry) then wget.
cs_download() {
	local url="$1" out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fSL --retry 3 --retry-delay 2 -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		hc_err "neither curl nor wget on PATH — cannot download $url"; return 1
	fi
}

# _cs_fetch_extract <ver> <libdir> <tmp> — download + (best-effort) checksum-verify
# + extract the pinned tarball into <libdir>/code-server-<ver>-<arch>. Stages under
# <tmp> (caller owns <tmp> cleanup). Returns non-zero on any failure.
_cs_fetch_extract() {
	local ver="$1" libdir="$2" tmp="$3"
	local dir="code-server-${ver}-${CS_ARCH}" dest="$libdir/code-server-${ver}-${CS_ARCH}"
	local base="https://github.com/coder/code-server/releases/download/v${ver}"
	local tarball="${dir}.tar.gz"
	hc_info "downloading $tarball from GitHub releases (standalone tarball, no npm)…"
	cs_download "$base/$tarball" "$tmp/$tarball" \
		|| { hc_err "download failed: $base/$tarball"; return 1; }

	# Verify the published checksum when the release ships one (best-effort — the
	# runtime `--version` in cs_install_tarball is the authoritative §11.4.6 FACT;
	# coder/code-server currently publishes no per-release checksum file).
	local sum_ok="" cand want got
	for cand in "${tarball}.sha256" "sha256sums.txt" "SHA256SUMS"; do
		cs_download "$base/$cand" "$tmp/$cand" 2>/dev/null || continue
		want="$(grep -F "$tarball" "$tmp/$cand" 2>/dev/null | grep -oiE '[0-9a-f]{64}' | head -n1 || true)"
		[ -n "$want" ] || want="$(grep -oiE '[0-9a-f]{64}' "$tmp/$cand" 2>/dev/null | head -n1 || true)"
		[ -n "$want" ] || continue
		got="$(sha256sum "$tmp/$tarball" | awk '{print $1}')"
		if [ "$want" = "$got" ]; then hc_info "checksum verified ($cand): $got"; sum_ok=1; break
		else hc_err "checksum MISMATCH for $tarball: want=$want got=$got"; return 1; fi
	done
	[ -n "$sum_ok" ] || hc_warn "no published checksum for $tarball — relying on runtime --version FACT (§11.4.6)."

	hc_info "extracting $tarball -> $libdir/"
	mkdir -p "$libdir" "$tmp/x"
	tar -xzf "$tmp/$tarball" -C "$tmp/x"
	[ -x "$tmp/x/$dir/bin/code-server" ] \
		|| { hc_err "extracted tree missing $dir/bin/code-server — bad tarball?"; return 1; }
	rm -rf "$dest"           # replace ONLY our own versioned prefix — never a shared path.
	mv "$tmp/x/$dir" "$dest"
}

# cs_install_tarball <ver> <libdir> <bindir> — install code-server from the pinned
# standalone tarball into <libdir> and symlink <bindir>/code-server onto it.
# Idempotent (re-uses an already-extracted pinned version), NON-root; PROVES
# success by running the extracted binary's `--version` == <ver> (§11.4.6). Prints
# the resolved binary path. Returns non-zero on any failure (caller may fall back).
cs_install_tarball() {
	local ver="$1" libdir="$2" bindir="$3"
	local dest="$libdir/code-server-${ver}-${CS_ARCH}" bin
	bin="$dest/bin/code-server"
	if [ -x "$bin" ] && "$bin" --version 2>/dev/null | head -n1 | grep -q "^${ver} "; then
		hc_info "code-server $ver already extracted at $dest (idempotent skip)"
	else
		local tmp rc=0; tmp="$(mktemp -d)"
		_cs_fetch_extract "$ver" "$libdir" "$tmp" || rc=$?
		rm -rf "$tmp"
		[ "$rc" -eq 0 ] || return "$rc"
	fi
	mkdir -p "$bindir"
	ln -sfn "$dest/bin/code-server" "$bindir/code-server"
	# §11.4.6: PROVE the installed binary reports the pinned version — else fail.
	local rv
	rv="$("$dest/bin/code-server" --version 2>/dev/null | head -n1 | awk '{print $1}')"
	[ "$rv" = "$ver" ] \
		|| { hc_err "version check FAILED: extracted code-server reports '$rv', expected '$ver'"; return 1; }
	hc_info "verified code-server $rv -> $bindir/code-server"
	printf '%s\n' "$bindir/code-server"
}

# Self-test seam (§11.4.6 proof, NON-destructive): when HC_INSTALL_AUTH_SELFTEST is
# a directory, exercise ONLY the tarball fetch+extract+verify into it and exit —
# never touches ~/.local, systemd, or the live install. Lets the mechanism be
# proven in a mktemp sandbox without disrupting a working host.
if [ -n "${HC_INSTALL_AUTH_SELFTEST:-}" ]; then
	hc_info "SELF-TEST: installing code-server $CODE_SERVER_VERSION into sandbox $HC_INSTALL_AUTH_SELFTEST"
	cs_install_tarball "$CODE_SERVER_VERSION" "$HC_INSTALL_AUTH_SELFTEST/lib" "$HC_INSTALL_AUTH_SELFTEST/bin"
	hc_info "SELF-TEST OK: $("$HC_INSTALL_AUTH_SELFTEST/bin/code-server" --version 2>/dev/null | head -n1)"
	exit 0
fi

hc_info "== HelixCode real-account editor install (host-native, ssh-key) =="

# 0. Config from deploy/.env (defaults keep a bare host workable).
if [ -f "$HC_DEPLOY/.env" ]; then
	hc_load_env
else
	hc_warn "deploy/.env not found — using defaults (account=$(id -un), no PROJECTS_ROOT)."
	hc_warn "run scripts/setup.sh to configure, then re-run this script."
fi
: "${HELIX_AUTH_ACCOUNT:=$(id -un)}"
: "${HELIX_AUTH_MODE:=sshkey}"
: "${HELIX_AUTH_PRINCIPAL:=$HELIX_AUTH_ACCOUNT}"
: "${PROJECTS_ROOT:=}"
[ -n "$PROJECTS_ROOT" ] || hc_warn "PROJECTS_ROOT empty — code-server will open \$HOME (no editor file-tree jail)."
hc_info "account=$HELIX_AUTH_ACCOUNT  mode=$HELIX_AUTH_MODE  principal=$HELIX_AUTH_PRINCIPAL  projects_root=${PROJECTS_ROOT:-<home>}"

# 1. code-server — PRIMARY: pinned standalone GitHub-release tarball into
#    ~/.local/lib + symlink onto ~/.local/bin (NO sudo). FALLBACK: npm global.
#    The early `command -v` skip keeps a re-run on a host that already has
#    code-server from reinstalling over the working binary (§11.4.174-safe).
if command -v code-server >/dev/null 2>&1; then
	hc_info "code-server present: $(code-server --version 2>/dev/null | head -n1) — skipping install"
elif cs_install_tarball "$CODE_SERVER_VERSION" "$CS_LIB_DIR" "$BIN_DIR" >/dev/null; then
	command -v code-server >/dev/null 2>&1 \
		|| hc_warn "code-server installed at $BIN_DIR/code-server but not on PATH — add ~/.local/bin to PATH."
	hc_info "installed code-server $CODE_SERVER_VERSION (standalone tarball)"
else
	# Documented fallback: user npm global prefix (no sudo). Fragile on this host
	# (npm registry version lag + corrupted-tarball/ENOENT) — hence tarball-first.
	hc_warn "tarball install failed — falling back to npm global (code-server@$CODE_SERVER_VERSION)…"
	command -v npm >/dev/null 2>&1 \
		|| { hc_err "npm not on PATH and tarball failed — install Node.js/npm or fix network, then re-run"; exit 1; }
	npm install -g "code-server@${CODE_SERVER_VERSION}"
	command -v code-server >/dev/null 2>&1 \
		|| { hc_err "code-server not on PATH after npm install — check npm global prefix / PATH (~/.local/bin?)"; exit 1; }
	hc_info "installed via npm fallback: $(code-server --version 2>/dev/null | head -n1)"
fi

# 2. Build the helix-auth gate binary from services/auth_gate/ (pure Go, no cgo —
#    it execs ssh-keygen to verify signatures) into user-writable ~/.local/bin.
#    Warn + skip if the service source is not present yet; the gate is then simply
#    not started below (AUTH FAILS CLOSED by design until it runs).
if [ -d "$AUTH_GATE_SRC" ]; then
	command -v go >/dev/null 2>&1 || { hc_err "go not on PATH — needed to build the helix-auth gate"; exit 1; }
	mkdir -p "$BIN_DIR"
	hc_info "building helix-auth from $AUTH_GATE_SRC -> $BIN_DIR/helix-auth"
	( cd "$AUTH_GATE_SRC" && go build -o "$BIN_DIR/helix-auth" . )
	hc_info "built $BIN_DIR/helix-auth"
else
	hc_warn "services/auth_gate/ not found — skipping helix-auth build."
	hc_warn "build it later, then: systemctl --user start $AUTH_UNIT (AUTH FAILS CLOSED until then)."
fi

# 3. Seed the watcherExclude defaults into the host-native --user-data-dir (only
#    if absent — never clobber operator UI edits). Mirrors the container seeding
#    the old up.sh did, for the host-native path used by the systemd unit.
CS_DATA_DIR="$HOME/.local/share/helixcode/code-server"
if [ -f "$HC_DEPLOY/code-server/settings.default.json" ] && [ ! -f "$CS_DATA_DIR/User/settings.json" ]; then
	mkdir -p "$CS_DATA_DIR/User"
	cp "$HC_DEPLOY/code-server/settings.default.json" "$CS_DATA_DIR/User/settings.json"
	hc_info "seeded watcherExclude defaults -> $CS_DATA_DIR/User/settings.json"
fi

# 4. Install the systemd --user unit templates, substituting deploy/.env values.
#    ${PROJECTS_ROOT}, ${HELIX_AUTH_ACCOUNT} and ${HELIX_AUTH_PRINCIPAL} are the
#    placeholders; %h (and the %h/.ssh/authorized_keys literal in helix-auth) are
#    native systemd specifiers left for systemd to expand at runtime.
# Resolve the code-server binary dir (user npm global prefix bin, e.g. ~/.npm-global/bin)
# so the bare `code-server` ExecStart resolves under systemd's minimal --user PATH.
CS_BIN_DIR="$(dirname "$(command -v code-server 2>/dev/null || echo "$HOME/.local/bin/code-server")")"
mkdir -p "$USER_UNIT_DIR"
render_unit() {
	local name="$1" src dst
	src="$TEMPLATE_DIR/$name"; dst="$USER_UNIT_DIR/$name"
	[ -f "$src" ] || { hc_err "missing unit template: $src"; exit 1; }
	sed -e "s|\${PROJECTS_ROOT}|${PROJECTS_ROOT}|g" \
	    -e "s|\${HELIX_AUTH_ACCOUNT}|${HELIX_AUTH_ACCOUNT}|g" \
	    -e "s|\${HELIX_AUTH_PRINCIPAL}|${HELIX_AUTH_PRINCIPAL}|g" \
	    -e "s|\${CS_BIN_DIR}|${CS_BIN_DIR}|g" \
	    "$src" > "$dst"
	hc_info "installed unit -> $dst"
}
render_unit "$CS_UNIT"
render_unit "$AUTH_UNIT"

# 5. Ensure own-user linger (services survive logout — idempotent + own-user only,
#    so §11.4.174-safe), reload, enable + start ONLY our two units. code-server was
#    just ensured; start the helix-auth gate only if its binary is present so a
#    not-yet-built gate does not hard-fail the install.
loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user enable "$CS_UNIT" "$AUTH_UNIT"
# restart (NOT start): a re-run MUST apply unit/template changes; `start` is a
# no-op on an already-running service and would silently keep the old process.
systemctl --user restart "$CS_UNIT" || hc_warn "restart failed: $CS_UNIT — check: systemctl --user status $CS_UNIT"
if command -v helix-auth >/dev/null 2>&1 || [ -x "$BIN_DIR/helix-auth" ]; then
	systemctl --user restart "$AUTH_UNIT" || hc_warn "restart failed: $AUTH_UNIT — check: systemctl --user status $AUTH_UNIT"
else
	hc_warn "helix-auth binary not found (~/.local/bin) — build services/auth_gate, then: systemctl --user start $AUTH_UNIT"
	hc_warn "AUTH FAILS CLOSED by design: until the gate runs, Caddy denies the app."
fi
hc_info "units enabled (systemd --user): $CS_UNIT $AUTH_UNIT"

hc_info "login is ssh-key challenge-response — no password, no sudo, no /etc/pam.d."
hc_info "done. Bring the Caddy edge up with: deploy/up.sh  (proxies to the gate)."
