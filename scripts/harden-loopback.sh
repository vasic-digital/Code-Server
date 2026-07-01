#!/usr/bin/env bash
# scripts/harden-loopback.sh — UID-scoped loopback firewall for host-native code-server.
#
# Purpose:      Close the documented `--auth none` residual risk of the host-native
#               real-account editor. code-server listens on 127.0.0.1:8080 with
#               `--auth none` (auth is enforced UPSTREAM by the Caddy forward_auth
#               gate), so on the raw loopback socket there is NO per-UID access
#               control: ANY local process/user in the host network namespace can
#               connect to 127.0.0.1:8080 and get an interactive shell AS the
#               account, bypassing the Caddy gate entirely (see the RESIDUAL RISK
#               block in deploy/systemd/helix-code-server.service, FINDINGS Angle
#               2/D). This script installs the host-side mitigation named there:
#               a UID-scoped loopback OUTPUT firewall rule that DROPs connections
#               to 127.0.0.1:<port> made by any UID other than the account, so ONLY
#               the account reaches code-server. Rootless Caddy connects AS the
#               account (via host.containers.internal → host loopback), so the gate
#               path stays allowed; rootless-Podman pods sit in their own netns and
#               never reach host loopback unless host-networked.
#
#               This is a defence-in-depth complement to the fail-closed Caddy gate,
#               NOT a replacement for it. It does not weaken §11.4.133 host safety:
#               it adds one narrow OUTPUT DROP rule in a DEDICATED nft table (or a
#               single iptables OUTPUT rule) and touches nothing else.
#
# Usage:        scripts/harden-loopback.sh --check   # read-only; NO root needed
#               scripts/harden-loopback.sh --apply   # add the rule (REQUIRES root)
#               scripts/harden-loopback.sh --remove  # delete the rule (REQUIRES root)
#               scripts/harden-loopback.sh -h|--help # show this header
#
#               --check   prints the resolved account/UID/port, the detected
#                         firewall backend, the current rule state, and the EXACT
#                         rule it WOULD add (dry-run). Exit 0 = rule confirmed
#                         present (PROTECTED); exit 1 = rule absent OR state could
#                         not be confirmed (fail-closed reporting — never claims
#                         protection it did not verify).
#               --apply   idempotent: adds the rule only if absent. REFUSES politely
#                         with the exact root re-run instruction when not run as
#                         root — it NEVER escalates privileges itself (no sudo/su
#                         invocation, §11.4.133 / operator directive).
#               --remove  idempotent: deletes the rule if present. Also root-only.
#
# Inputs:       deploy/.env — HELIX_AUTH_ACCOUNT (the real host user the editor ties
#                             to; the ONLY UID allowed through the rule). Required —
#                             the script REFUSES to guess an account for a security
#                             control (§11.4.6). Overridable via the HELIX_AUTH_ACCOUNT
#                             environment variable (§11.4.28 config injection).
#               Port        — HELIX_CS_PORT env/.env override if set; else parsed from
#                             the `--bind-addr 127.0.0.1:<port>` line of
#                             deploy/systemd/helix-code-server.service (the real
#                             deployed value, not a literal); else the documented
#                             default 8080. Never blindly hardcoded (§11.4.6).
# Outputs:      Human-readable state + the exact rule text (all modes). --apply /
#               --remove additionally mutate the firewall (root only).
# Side-effects: --apply adds (idempotently) a UID-scoped OUTPUT DROP rule for
#               127.0.0.1:<port>. With nftables: a DEDICATED table `inet
#               helixcode_loopback` + an `output` filter chain + the rule (so
#               removal is a clean single-table delete that cannot disturb other
#               firewalling). With iptables: one OUTPUT rule using the `owner`
#               match. --check has NO side effects. This script NEVER runs sudo/su,
#               NEVER binds 0.0.0.0, NEVER touches services/tests/deploy sources.
# Dependencies: bash; id, grep; and — for --apply/--remove only — root + one of
#               nft (preferred) or iptables. scripts/lib.sh (logging + .env load).
# Cross-references: deploy/systemd/helix-code-server.service (RESIDUAL RISK block),
#               deploy/compose.codeserver.yml (deferred unix-socket note),
#               docs/scripts/harden-loopback.md, docs/guides/AUTH.md (§5.1 security),
#               §11.4.6, §11.4.18, §11.4.28, §11.4.133.
set -euo pipefail

# shellcheck source=scripts/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --help prints the leading §11.4.18 doc block (comment lines from line 2 on).
case "${1:-}" in
	-h|--help)
		awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print;next} exit }' "${BASH_SOURCE[0]}"
		exit 0
		;;
esac

# --- configuration resolution (never guess for a security control, §11.4.6) ------

# Capture operator-provided overrides from the PROCESS environment BEFORE sourcing
# deploy/.env — otherwise `hc_load_env` (which does `set -a; . .env`) would clobber
# an explicitly-exported value with the .env one. Precedence (§11.4.28 config
# injection): process env > deploy/.env > derived-from-unit > documented default.
_OVERRIDE_ACCOUNT="${HELIX_AUTH_ACCOUNT:-}"
_OVERRIDE_PORT="${HELIX_CS_PORT:-}"

# Load deploy/.env if present (sets HELIX_AUTH_ACCOUNT, and optionally HELIX_CS_PORT).
hc_load_env

# Account — the ONLY UID allowed through the rule. REQUIRED. We do NOT fall back to
# `id -un`: under `--apply` the script may run as root, where `id -un` would be
# `root`, producing a WRONG rule that locks the real account out (§11.4.6).
ACCOUNT="${_OVERRIDE_ACCOUNT:-${HELIX_AUTH_ACCOUNT:-}}"
if [ -z "$ACCOUNT" ]; then
	hc_err "HELIX_AUTH_ACCOUNT is not set (deploy/.env absent or empty)."
	hc_err "This UID-scoped firewall rule cannot be built without the account —"
	hc_err "refusing to guess a security-relevant identity (§11.4.6)."
	hc_err "Set it in deploy/.env (run scripts/setup.sh) or pass HELIX_AUTH_ACCOUNT=<user>."
	exit 1
fi

# Resolve the numeric UID (unambiguous across nft/iptables). A non-existent account
# is a hard error — the rule would otherwise be meaningless.
if ! ACCOUNT_UID="$(id -u "$ACCOUNT" 2>/dev/null)"; then
	hc_err "account '$ACCOUNT' is not a real host user (id -u failed) — cannot build the rule."
	exit 1
fi

# Port — HELIX_CS_PORT override, else parse the real deployed bind-addr, else 8080.
resolve_port() {
	local unit p
	# Process-env override wins over .env (§11.4.28); then .env's own HELIX_CS_PORT.
	if [ -n "$_OVERRIDE_PORT" ]; then
		printf '%s\n' "$_OVERRIDE_PORT"
		return 0
	fi
	if [ -n "${HELIX_CS_PORT:-}" ]; then
		printf '%s\n' "$HELIX_CS_PORT"
		return 0
	fi
	unit="$HC_DEPLOY/systemd/helix-code-server.service"
	if [ -f "$unit" ]; then
		p="$(grep -oE 'bind-addr[[:space:]]+127\.0\.0\.1:[0-9]+' "$unit" 2>/dev/null \
			| grep -oE '[0-9]+$' | head -n1 || true)"
		if [ -n "$p" ]; then
			printf '%s\n' "$p"
			return 0
		fi
	fi
	# Documented default: the value the systemd unit binds (§11.4.6 — a documented
	# fact, not a guess). Overridable via HELIX_CS_PORT.
	printf '%s\n' "8080"
}
PORT="$(resolve_port)"
case "$PORT" in
	'' | *[!0-9]*)
		hc_err "resolved port '$PORT' is not numeric — refusing to build a firewall rule (§11.4.6)."
		exit 1
		;;
esac

# --- backend detection (prefer nftables) -----------------------------------------

# detect_backend — echo "nft" | "iptables" | "none". nft preferred per requirement.
detect_backend() {
	if command -v nft >/dev/null 2>&1; then
		echo "nft"
	elif command -v iptables >/dev/null 2>&1; then
		echo "iptables"
	else
		echo "none"
	fi
}

# nftables uses a DEDICATED table so removal is a clean, self-contained delete.
# Family + name are separate tokens (nft needs them as distinct arguments); a
# combined SPEC string is kept for human-readable display only.
NFT_FAMILY="inet"
NFT_TABLE="helixcode_loopback"
NFT_CHAIN="output"
NFT_TABLE_SPEC="$NFT_FAMILY $NFT_TABLE"

# rule_text BACKEND — echo the exact rule that closes the residual risk, for the
# given backend, with the resolved UID + port substituted. Printed verbatim in
# --check (dry-run) and executed by --apply.
rule_text() {
	case "$1" in
		nft)
			printf 'nft add rule %s %s oifname "lo" tcp dport %s meta skuid != %s drop\n' \
				"$NFT_TABLE_SPEC" "$NFT_CHAIN" "$PORT" "$ACCOUNT_UID"
			;;
		iptables)
			printf 'iptables -A OUTPUT -o lo -p tcp --dport %s -m owner ! --uid-owner %s -j DROP\n' \
				"$PORT" "$ACCOUNT_UID"
			;;
	esac
}

# rule_present BACKEND — return 0 if the rule is present, 1 if absent, 2 if the
# ruleset could not be read (e.g. needs root). Never fabricates a verdict.
rule_present() {
	case "$1" in
		nft)
			local listing
			if ! listing="$(nft list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null)"; then
				# Table missing => our rule is absent; but nft may also refuse to
				# read without CAP_NET_ADMIN. Distinguish by a permission probe.
				if nft list ruleset >/dev/null 2>&1; then
					return 1   # readable, table simply not there
				fi
				return 2       # could not read ruleset (need root)
			fi
			if printf '%s\n' "$listing" \
				| grep -qE "dport $PORT .*skuid != $ACCOUNT_UID .*drop"; then
				return 0
			fi
			return 1
			;;
		iptables)
			if iptables -C OUTPUT -o lo -p tcp --dport "$PORT" \
				-m owner ! --uid-owner "$ACCOUNT_UID" -j DROP >/dev/null 2>&1; then
				return 0
			fi
			# -C returns non-zero for BOTH "absent" and "cannot read (need root)".
			# Probe read access to tell them apart honestly.
			if iptables -S OUTPUT >/dev/null 2>&1; then
				return 1
			fi
			return 2
			;;
	esac
	return 2
}

require_root() {
	local mode="$1" self
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi
	self="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/$(basename "${BASH_SOURCE[0]}")"
	hc_err "'$mode' modifies the host firewall and REQUIRES root."
	hc_err "This script never escalates privileges itself — re-run it as root, e.g.:"
	hc_err "    su - -c 'HELIX_AUTH_ACCOUNT=$ACCOUNT HELIX_CS_PORT=$PORT \"$self\" $mode'"
	hc_err "(or use your site's own root path — sudo, doas, a root login shell, …)."
	return 1
}

# --- modes -----------------------------------------------------------------------

do_check() {
	local backend
	backend="$(detect_backend)"
	hc_info "== harden-loopback --check =="
	hc_info "account : $ACCOUNT (uid $ACCOUNT_UID)"
	hc_info "target  : 127.0.0.1:$PORT (host-native code-server, --auth none)"
	hc_info "backend : $backend"

	if [ "$backend" = "none" ]; then
		hc_warn "no firewall backend found (nft/iptables not on PATH)."
		hc_warn "state   : CANNOT VERIFY — treating 127.0.0.1:$PORT as UNPROTECTED."
		echo
		hc_info "rule that WOULD be added (install iptables or nftables, then --apply as root):"
		printf '  # nftables (preferred):\n'
		printf '    nft add table %s\n' "$NFT_TABLE_SPEC"
		printf '    nft add chain %s %s { type filter hook output priority 0 \; policy accept \; }\n' \
			"$NFT_TABLE_SPEC" "$NFT_CHAIN"
		printf '    %s\n' "$(rule_text nft)"
		printf '  # iptables (fallback):\n'
		printf '    %s\n' "$(rule_text iptables)"
		return 1
	fi

	echo
	hc_info "rule that WOULD be added (--apply, requires root):"
	if [ "$backend" = "nft" ]; then
		printf '    nft add table %s\n' "$NFT_TABLE_SPEC"
		printf '    nft add chain %s %s { type filter hook output priority 0 \; policy accept \; }\n' \
			"$NFT_TABLE_SPEC" "$NFT_CHAIN"
	fi
	printf '    %s\n' "$(rule_text "$backend")"
	echo

	rule_present "$backend"
	case "$?" in
		0)
			hc_info "state   : PROTECTED — the UID-scoped loopback rule is present."
			return 0
			;;
		1)
			hc_warn "state   : UNPROTECTED — the rule is ABSENT. Any local UID can reach 127.0.0.1:$PORT."
			hc_warn "          Apply it as root:  scripts/harden-loopback.sh --apply"
			return 1
			;;
		*)
			hc_warn "state   : UNKNOWN — could not read the $backend ruleset (needs root)."
			hc_warn "          Re-run --check as root to confirm, or just --apply (idempotent)."
			return 1
			;;
	esac
}

do_apply() {
	local backend
	# Root is the universal precondition for a mutating op — refuse first (with the
	# exact root re-run instruction) and never escalate ourselves.
	require_root "--apply" || return 1
	backend="$(detect_backend)"
	if [ "$backend" = "none" ]; then
		hc_err "no firewall backend found (nft/iptables not on PATH) — cannot apply."
		hc_err "install nftables (preferred) or iptables, then re-run --apply as root."
		return 1
	fi

	if rule_present "$backend"; then
		hc_info "already protected — the rule for 127.0.0.1:$PORT (uid $ACCOUNT_UID) is present. Nothing to do."
		return 0
	fi

	hc_info "applying UID-scoped loopback rule via $backend for 127.0.0.1:$PORT (allow only uid $ACCOUNT_UID)…"
	if [ "$backend" = "nft" ]; then
		nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 \
			|| nft add table "$NFT_FAMILY" "$NFT_TABLE"
		nft list chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 \
			|| nft add chain "$NFT_FAMILY" "$NFT_TABLE" "$NFT_CHAIN" '{ type filter hook output priority 0 ; policy accept ; }'
		nft add rule "$NFT_FAMILY" "$NFT_TABLE" "$NFT_CHAIN" oifname "lo" tcp dport "$PORT" meta skuid != "$ACCOUNT_UID" drop
	else
		iptables -A OUTPUT -o lo -p tcp --dport "$PORT" -m owner ! --uid-owner "$ACCOUNT_UID" -j DROP
	fi

	if rule_present "$backend"; then
		hc_info "applied. 127.0.0.1:$PORT now reachable ONLY by uid $ACCOUNT_UID (and rootless Caddy, which connects AS it)."
		hc_info "NOTE: nft/iptables rules are runtime state — re-apply on boot (persist via your distro's ruleset save, or a boot unit)."
		return 0
	fi
	hc_err "rule did not take effect after apply — inspect: nft list ruleset / iptables -S OUTPUT"
	return 1
}

do_remove() {
	local backend
	require_root "--remove" || return 1
	backend="$(detect_backend)"
	if [ "$backend" = "none" ]; then
		hc_err "no firewall backend found (nft/iptables not on PATH) — nothing to remove."
		return 1
	fi

	if ! rule_present "$backend"; then
		hc_info "not present — no UID-scoped loopback rule for 127.0.0.1:$PORT to remove. Nothing to do."
		return 0
	fi

	hc_info "removing UID-scoped loopback rule via $backend for 127.0.0.1:$PORT…"
	if [ "$backend" = "nft" ]; then
		# Our dedicated table holds only this control — a table delete is a clean,
		# self-contained removal that cannot disturb any other firewalling.
		nft delete table "$NFT_FAMILY" "$NFT_TABLE"
	else
		iptables -D OUTPUT -o lo -p tcp --dport "$PORT" -m owner ! --uid-owner "$ACCOUNT_UID" -j DROP
	fi
	hc_info "removed. 127.0.0.1:$PORT is again reachable by any local UID (residual risk restored)."
	return 0
}

# --- dispatch --------------------------------------------------------------------

case "${1:-}" in
	--check)  do_check ;;
	--apply)  do_apply ;;
	--remove) do_remove ;;
	'' )
		hc_err "no mode given. Usage: scripts/harden-loopback.sh --check | --apply | --remove | --help"
		exit 2
		;;
	*)
		hc_err "unknown option: $1"
		hc_err "Usage: scripts/harden-loopback.sh --check | --apply | --remove | --help"
		exit 2
		;;
esac
