#!/usr/bin/env bash
# scripts/install-auth.sh — install the host-native real-account editor + ssh-key gate.
#
# Purpose:      Wire up the host-native side of the real-account code-server model
#               with SSH-KEY challenge-response login (spec
#               docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md):
#               (1) install code-server via the user's npm global prefix (no sudo);
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
# Outputs:      code-server on PATH (user npm global); helix-auth at ~/.local/bin
#               (when services/auth_gate/ is present); rendered units at
#               ~/.config/systemd/user/{helix-code-server,helix-auth}.service;
#               enabled (+ started where the binary is present) --user services.
# Side-effects: runs `npm install -g code-server@<ver>` (user prefix) if absent;
#               `go build` of the gate into user-writable ~/.local/bin if source
#               present; writes the two --user unit files; `systemctl --user
#               daemon-reload` + enable/start of ONLY those two units; ensures
#               own-user linger; seeds code-server watcherExclude defaults if absent.
#               NEVER touches/stops/kills any process, container, or unit not named
#               helix-code-server / helix-auth (§11.4.174). NEVER runs sudo/root.
# Dependencies: bash; npm (Node.js); go (for the gate build); systemd (--user,
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
# code-server version pin. Installed via `npm i -g` below, so this MUST be a
# version PUBLISHED ON NPM. Evidence 2026-07-01 (§11.4.6): `npm view code-server
# version` = 4.117.0 — the newest on the npm registry. 4.118–4.126 exist as GitHub
# releases / standalone tarballs but are NOT (yet) published to npm, so
# `npm i -g code-server@4.126.0` fails E404 — pinning it would break this
# installer. 4.117.0 is patched against CVE-2025-47269 (fixed >=4.99.4).
# §11.4.112 conscious-hold on the npm-vs-GitHub lag; re-pin to the newest
# npm-published version at review (2026-08-01). Override: CODE_SERVER_VERSION=…
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.117.0}"
BIN_DIR="$HOME/.local/bin"
AUTH_GATE_SRC="$HC_ROOT/services/auth_gate"

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

# 1. code-server via the user npm global prefix (NO sudo). Idempotent.
if command -v code-server >/dev/null 2>&1; then
	hc_info "code-server present: $(code-server --version 2>/dev/null | head -n1)"
else
	command -v npm >/dev/null 2>&1 || { hc_err "npm not on PATH — install Node.js/npm first"; exit 1; }
	hc_info "installing code-server@$CODE_SERVER_VERSION via user npm global (no sudo)…"
	npm install -g "code-server@${CODE_SERVER_VERSION}"
	command -v code-server >/dev/null 2>&1 \
		|| { hc_err "code-server not on PATH after install — check npm global prefix / PATH (~/.local/bin?)"; exit 1; }
	hc_info "installed $(code-server --version 2>/dev/null | head -n1)"
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
