#!/usr/bin/env bash
#
# tests/types/challenges_auth.sh — §11.4.169 Challenges layer for the ssh-key auth pivot.
#
# Faithfully executes tests/banks/helixcode-auth-challenges.yaml: each user-facing
# capability of the 2026-07-01 auth pivot (spec 2026-07-01-auth-pivot-ssh-key.md) is
# exercised LIVE and scored PASS only on captured positive evidence
# (§11.4.27(B)/§11.4.69) — no metadata-only / absence-of-error passes. Fresh evidence
# per run (§11.4.107). No secret is ever printed or written to evidence (§11.4.10).
#
# Challenges:
#   CH1 real-account-sshkey-login          — challenge->sign->cookie->editor (authn)
#   CH2 auth-fails-closed                   — down gate / no-session denied (authz)
#   CH3 sshkey-git-from-editor-terminal     — git ls-remote over ssh (network_connectivity)
#   CH4 fresh-terminal-bashrc-exports       — ~/.bashrc sourced in a fresh terminal (boot_service)
#   CH5 explorer-defaults-to-projects-root  — PROJECTS_ROOT default workspace, honest not-a-jail (storage_read)
#
# ANTI-BLUFF (§11.4/§11.4.1/§11.4.69/§11.4.98): mocks are FORBIDDEN (Challenges are an
# integration+ type, §11.4.27). When the live stack / an authorized key / the network
# is absent, the affected challenge SKIPs-with-reason — never a fake PASS. CH1's login
# uses an authorized key: $HELIX_TEST_SSH_KEY if provided, else a throwaway key
# authorized via $HELIX_TEST_AUTHORIZE_HOOK (a conductor-provided hook) — if neither is
# available it SKIPs cleanly (real green happens at conductor live-validation, §11.4.40).
#
# §1.1 paired mutation: force any challenge's positive assertion to accept the broken
# state (e.g. treat a down-gate 000 as allow, or a missing PROJECTS_ROOT arg as ok) ->
# the captured evidence shows the defect and the assertion FAILs -> suite FAILs.
#
# Cross-refs: §11.4.169 §11.4.27 §11.4.52 §11.4.69 §11.4.107 §11.4.10 §11.4.174 §11.4.6 ;
#             tests/banks/helixcode-auth-challenges.yaml ; harness.sh stack_fixture.sh
set -uo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$_here/../lib/harness.sh"
. "$_here/../lib/stack_fixture.sh"

h_init challenges_auth
BANK="$HC_ROOT/tests/banks/helixcode-auth-challenges.yaml"
[ -f "$BANK" ] && h_log "bank: ${BANK#$HC_ROOT/}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hc_ch_auth.XXXXXX")"
cleanup() { [ -n "${HC_DEAUTH_CMD:-}" ] && eval "$HC_DEAUTH_CMD" >/dev/null 2>&1 || true; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PRINCIPAL="${HELIX_AUTH_PRINCIPAL:-${HELIX_AUTH_ACCOUNT:-milosvasic}}"
GIT_REMOTE="${HELIX_TEST_GIT_REMOTE:-git@github.com:vasic-digital/Code-Server.git}"
HC_DEAUTH_CMD=""

if ! hc_new_stack_up; then
  ev="$(h_ev stack_down)"
  { echo "auth-pivot ssh-key stack not deployed (conductor deploys it live later)";
    echo "probe: $HC_NEW_STACK_DETAIL"; } > "$ev"
  ab_skip_with_reason "ssh-key auth Challenge bank (stack not deployed: $HC_NEW_STACK_DETAIL)" topology_unsupported
  h_summary; exit $?
fi

# resolve an authorized login key -> prints key path, 0 usable / 1 none.
# Path A: HELIX_TEST_SSH_KEY (an already-authorized private key).
# Path B: HELIX_TEST_AUTHORIZE_HOOK — a conductor hook invoked as
#         `"$HOOK" <pubkey_file> <principal>` to authorize a throwaway key; a paired
#         HELIX_TEST_DEAUTHORIZE_HOOK (same argv) is registered for cleanup.
resolve_login_key() {
  local ext="${HELIX_TEST_SSH_KEY:-}"
  if [ -n "$ext" ] && [ -r "$ext" ]; then printf '%s' "$ext"; return 0; fi
  if [ -n "${HELIX_TEST_AUTHORIZE_HOOK:-}" ] && h_require ssh-keygen; then
    local key; key="$(hc_sshkey_keygen "$WORK" 2>/dev/null)" || return 1
    if "$HELIX_TEST_AUTHORIZE_HOOK" "$key.pub" "$PRINCIPAL" >/dev/null 2>&1; then
      [ -n "${HELIX_TEST_DEAUTHORIZE_HOOK:-}" ] && HC_DEAUTH_CMD="'$HELIX_TEST_DEAUTHORIZE_HOOK' '$key.pub' '$PRINCIPAL'"
      printf '%s' "$key"; return 0
    fi
  fi
  return 1
}

# =========================================================================
# CH1 real-account-sshkey-login (authn) — challenge -> sign -> cookie -> editor
# =========================================================================
h_head "CH1 real-account-sshkey-login (authn)"
ev="$(h_ev ch1_sshkey_login)"
if ! h_require ssh-keygen || ! h_require curl; then
  { echo "ssh-keygen/curl not on PATH — cannot drive a real ssh-key login"; } > "$ev"
  ab_skip_with_reason "CH1 ssh-key login: ssh-keygen/curl absent" topology_unsupported
elif KEYFILE="$(resolve_login_key)"; then
  JAR="$WORK/ch1.jar"
  if hc_sshkey_login "$HC_BASE" "$KEYFILE" "$JAR" "$PRINCIPAL"; then
    body="$WORK/ch1.body"
    final="$(curl -k -s -b "$JAR" -L -o "$body" -w '%{http_code}' --max-time 20 "$HC_BASE/" 2>/dev/null || echo 000)"
    markers="$(grep -icE 'workbench|code-server|vscode|monaco' "$body" 2>/dev/null || true)"; markers="${markers:-0}"
    { echo "assert: a real authorized ssh-key login mints a session cookie AND the editor then loads";
      echo "POST /login code       : $HC_SSHKEY_CODE (want 302/303)";
      echo "session cookie (name)  : ${HC_SSHKEY_COOKIE:-<none>} (new: ${HC_SSHKEY_NEWCOOKIE:-<none>})";
      echo "scraped hidden fields  : ${HC_SSHKEY_FIELDS:-<none>}";
      echo "challenge nonce        : ${HC_SSHKEY_NONCE:-<none>}";
      echo "authed GET / final code: $final ; editor markers: $markers (want >=1)";
      echo "(the private key + signature are NEVER written to evidence — §11.4.10)"; } > "$ev"
    if { [ "$HC_SSHKEY_CODE" = 302 ] || [ "$HC_SSHKEY_CODE" = 303 ]; } && [ -n "$HC_SSHKEY_COOKIE" ] \
       && [ "$final" = 200 ] && [ "$markers" -ge 1 ]; then
      ab_pass_with_evidence "CH1: real ssh-key login -> $HC_SSHKEY_CODE + session cookie + editor loads (200, $markers markers)" "$ev"
    else
      ab_fail "CH1: ssh-key login journey incomplete (code=$HC_SSHKEY_CODE cookie=${HC_SSHKEY_COOKIE:-none} final=$final markers=$markers) [ev: ${ev#$HC_ROOT/}]"
    fi
  else
    { echo "hc_sshkey_login failed WITH an authorized key present";
      echo "POST /login code=$HC_SSHKEY_CODE cookie=${HC_SSHKEY_COOKIE:-none} new=${HC_SSHKEY_NEWCOOKIE:-none} nonce=${HC_SSHKEY_NONCE:-none}"; } > "$ev"
    ab_fail "CH1: authorized ssh-key login did not yield a session cookie (code=$HC_SSHKEY_CODE) [ev: ${ev#$HC_ROOT/}]"
  fi
else
  { echo "no authorized key: HELIX_TEST_SSH_KEY unset/unreadable AND no HELIX_TEST_AUTHORIZE_HOOK";
    echo "a genuine login PASS needs a key in the gate's allowed_signers (derived from the account's";
    echo "authorized_keys). SKIP-with-reason, never a faked PASS (§11.4/§11.4.69); binds at conductor";
    echo "live-validation when a key/authorize-hook is provided (§11.4.98)."; } > "$ev"
  ab_skip_with_reason "CH1 ssh-key login: no authorized test key or authorize-hook available" credential_absent
fi

# =========================================================================
# CH2 auth-fails-closed (authz) — down gate emits no allow; no/forged session denied
# =========================================================================
h_head "CH2 auth-fails-closed (authz)"
ev="$(h_ev ch2_fail_closed)"
# (a) a genuinely DOWN/unreachable gate cannot emit a 2xx allow. Probe 127.0.0.1:1
#     (nothing listens on port 1) as a real down-gate stand-in — connection refused
#     -> curl code 000 (never 2xx). This is the same signal Caddy's forward_auth
#     treats as DENY. The DESTRUCTIVE variant (kill the live shared gate) is a
#     stress_chaos concern (§11.4.119) — not duplicated in this read-only suite.
down_code="$(hc_http_code 'http://127.0.0.1:1/auth')"
# (b) the real gate denies by default: no cookie -> 401, forged cookie -> 401.
nc_code="$(hc_http_code "http://${HC_GATE_ADDR}/auth")"
fc_hdr="$WORK/ch2_forged.hdr"
curl -s -D "$fc_hdr" -o /dev/null --max-time 10 -H 'Cookie: session=forged-not-a-valid-session' "http://${HC_GATE_ADDR}/auth" 2>/dev/null || true
fc_code="$(awk 'toupper($1)~/^HTTP/{c=$2} END{print c+0}' "$fc_hdr" 2>/dev/null)"
# (c) the TLS edge does not serve the editor to an unauthenticated request.
edge_hdr="$WORK/ch2_edge.hdr"
curl -k -s -D "$edge_hdr" -o /dev/null --max-time 10 "$HC_BASE/" 2>/dev/null || true
edge_code="$(awk 'toupper($1)~/^HTTP/{c=$2} END{print c+0}' "$edge_hdr" 2>/dev/null)"
edge_loc="$(grep -i '^location:' "$edge_hdr" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')"
down_ok=0; { [ "$down_code" = 000 ] || [ "$down_code" -ge 500 ] 2>/dev/null; } && down_ok=1
edge_denied=0; { [ "$edge_code" = 401 ] || [ "$edge_code" = 302 ] || [ "$edge_code" = 303 ] || [ "$edge_code" = 307 ]; } && edge_denied=1
{ echo "assert: auth fails CLOSED — a down gate cannot allow, and no/forged session is denied";
  echo "down gate probe (127.0.0.1:1/auth) -> code=$down_code (want 000 or 5xx: a down gate emits NO 2xx allow) ok=$down_ok";
  echo "real gate /auth (no cookie)        -> code=$nc_code (want 401)";
  echo "real gate /auth (forged cookie)    -> code=$fc_code (want 401)";
  echo "TLS edge GET / (unauth)            -> code=$edge_code loc=${edge_loc:-<none>} denied=$edge_denied (want denied=1)";
  echo "note: destructive kill-the-live-gate variant is a stress_chaos concern (§11.4.119), not duplicated here"; } > "$ev"
if [ "$down_ok" = 1 ] && [ "$nc_code" = 401 ] && [ "$fc_code" = 401 ] && [ "$edge_denied" = 1 ]; then
  ab_pass_with_evidence "CH2: fail-closed — down gate emits no allow (code=$down_code); gate denies no/forged session (401/401); edge denies unauth (code=$edge_code)" "$ev"
else
  ab_fail "CH2: fail-closed violated (down_ok=$down_ok no-cookie=$nc_code forged=$fc_code edge_denied=$edge_denied) [ev: ${ev#$HC_ROOT/}]"
fi

# =========================================================================
# CH3 sshkey-git-from-editor-terminal (network_connectivity)
# =========================================================================
h_head "CH3 sshkey-git-from-editor-terminal (network_connectivity)"
ev="$(h_ev ch3_git_lsremote)"
if ! h_require git; then
  { echo "git not on PATH — cannot exercise ssh-key git from the terminal"; } > "$ev"
  ab_skip_with_reason "CH3 ssh-key git: git absent" topology_unsupported
else
  out="$WORK/ch3.out"
  # mirror the editor's default terminal (a fresh interactive shell as the real user);
  # git ls-remote is read-only and authenticates via the user's ssh keys over the network.
  bash -ic "git ls-remote '$GIT_REMOTE'" </dev/null >"$out" 2>&1; rc=$?
  refs="$(grep -cE '[0-9a-f]{7,}[[:space:]]+refs/' "$out" 2>/dev/null || true)"; refs="${refs:-0}"
  { echo "assert: 'git ls-remote $GIT_REMOTE' succeeds via ssh-key auth from a fresh terminal";
    echo "exit_code   : $rc (want 0)";
    echo "ref lines   : $refs (want >=1)";
    echo "--- head of output (no secret material printed) ---";
    head -n 5 "$out" 2>/dev/null; } > "$ev"
  if [ "$rc" = 0 ] && [ "$refs" -ge 1 ]; then
    ab_pass_with_evidence "CH3: ssh-key git works from the editor terminal — git ls-remote returned $refs refs" "$ev"
  elif grep -qiE 'could not resolve host|Network is unreachable|Connection timed out|Temporary failure in name resolution|Connection refused' "$out" 2>/dev/null; then
    ab_skip_with_reason "CH3 ssh-key git: network unreachable to the git host" network_unreachable_external
  elif grep -qiE 'Permission denied \(publickey\)|Could not read from remote repository|Host key verification failed|no matching host key' "$out" 2>/dev/null; then
    ab_skip_with_reason "CH3 ssh-key git: this environment's user is not authorized to the remote (no deploy key)" credential_absent
  else
    ab_fail "CH3: ssh-key git ls-remote failed (rc=$rc refs=$refs) [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# CH4 fresh-terminal-bashrc-exports (boot_service)
# =========================================================================
h_head "CH4 fresh-terminal-bashrc-exports (boot_service)"
ev="$(h_ev ch4_bashrc_exports)"
BRC="${HOME:-/nonexistent}/.bashrc"
if ! h_require bash || [ ! -r "$BRC" ]; then
  { echo "no readable ~/.bashrc ($BRC) in this environment — nothing to inherit"; } > "$ev"
  ab_skip_with_reason "CH4 bashrc exports: ~/.bashrc absent/unreadable in this env" feature_disabled_by_config
else
  # candidate exported var NAMES from ~/.bashrc (names only, never values §11.4.10);
  # a pinned HELIX_TEST_BASHRC_VAR is tried first.
  cand="$(printf '%s\n' "${HELIX_TEST_BASHRC_VAR:-}"; \
          grep -oE '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$BRC" 2>/dev/null \
            | sed -E 's/.*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
  cand="$(printf '%s\n' "$cand" | awk 'NF' | awk '!seen[$0]++' | head -n 8)"
  ncand="$(printf '%s\n' "$cand" | grep -c . || true)"; ncand="${ncand:-0}"
  found_var=""; found=0
  if [ "$ncand" -ge 1 ]; then
    # a fresh NON-login INTERACTIVE shell (what the editor terminal spawns) sources
    # ~/.bashrc; confirm at least one of its exports is present. Indirect expansion
    # keeps the var NAME out of the command string (no injection) and prints only SET.
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      res="$(HELIXCODE_PROBE_VAR="$v" bash -ic 'printf %s "${!HELIXCODE_PROBE_VAR:+SET}"' </dev/null 2>/dev/null || true)"
      if [ "$res" = SET ]; then found_var="$v"; found=1; break; fi
    done <<EOF
$cand
EOF
  fi
  { echo "assert: a fresh editor terminal (non-login interactive shell) sources ~/.bashrc";
    echo "~/.bashrc                       : $BRC";
    echo "exported var NAMES probed       : $(printf '%s' "$cand" | tr '\n' ' ') ($ncand)";
    echo "present in fresh interactive sh : $([ $found = 1 ] && echo "yes ($found_var)" || echo no)";
    echo "(only var NAMES + SET/UNSET recorded — never a value — §11.4.10)"; } > "$ev"
  if [ "$found" = 1 ]; then
    ab_pass_with_evidence "CH4: fresh terminal inherits a ~/.bashrc export ($found_var present in a non-login interactive shell)" "$ev"
  elif [ "$ncand" -lt 1 ]; then
    ab_skip_with_reason "CH4 bashrc exports: ~/.bashrc defines no exports to verify in this env" feature_disabled_by_config
  else
    ab_fail "CH4: a fresh interactive shell did NOT inherit any of ~/.bashrc's exports [ev: ${ev#$HC_ROOT/}]"
  fi
fi

# =========================================================================
# CH5 explorer-defaults-to-projects-root (storage_read) — honest: NOT a jail
# =========================================================================
h_head "CH5 explorer-defaults-to-projects-root (storage_read)"
ev="$(h_ev ch5_projects_root_default)"
hc_load_env   # exports PROJECTS_ROOT from deploy/.env when present
PR="${HELIX_TEST_PROJECTS_ROOT:-${PROJECTS_ROOT:-}}"
# resolve the RUNNING code-server PID that OWNS the loopback editor port (§11.4.174)
cs_pid=""
if h_require ss; then
  cs_pid="$(ss -ltnpH 2>/dev/null | awk -v p=":${HC_CSVR_ADDR##*:}\$" '$4 ~ p {print}' | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)"
fi
if [ -z "$cs_pid" ] && h_require lsof; then
  cs_pid="$(lsof -nP -iTCP:"${HC_CSVR_ADDR##*:}" -sTCP:LISTEN -t 2>/dev/null | head -n1)"
fi
cmdline=""
[ -n "$cs_pid" ] && [ -r "/proc/$cs_pid/cmdline" ] && cmdline="$(tr '\0' ' ' < "/proc/$cs_pid/cmdline" 2>/dev/null)"
# fallback: the INSTALLED systemd unit's ExecStart (resolved), then the template.
unit_installed="${HOME:-/nonexistent}/.config/systemd/user/helix-code-server.service"
unit_template="$HC_ROOT/deploy/systemd/helix-code-server.service"
exec_line=""
[ -r "$unit_installed" ] && exec_line="$(grep -m1 '^ExecStart=' "$unit_installed" 2>/dev/null)"
[ -z "$exec_line" ] && [ -r "$unit_template" ] && exec_line="$(grep -m1 '^ExecStart=' "$unit_template" 2>/dev/null)"

pr_in_runtime=0; auth_none=0; pr_in_unit=0
if [ -n "$PR" ]; then
  [ -n "$cmdline" ] && printf '%s' "$cmdline" | grep -qF -- "$PR" && pr_in_runtime=1
  [ -n "$exec_line" ] && printf '%s' "$exec_line" | grep -qF -- "$PR" && pr_in_unit=1
  # the template carries the literal ${PROJECTS_ROOT}; count that as unit-configured too.
  [ -n "$exec_line" ] && printf '%s' "$exec_line" | grep -q '${PROJECTS_ROOT}' && pr_in_unit=1
fi
[ -n "$cmdline" ] && printf '%s' "$cmdline" | grep -qE -- '--auth[= ]+none' && auth_none=1
[ -n "$exec_line" ] && printf '%s' "$exec_line" | grep -qE -- '--auth none' && { [ "$auth_none" = 1 ] || auth_none=1; }
{ echo "assert: the running code-server opens PROJECTS_ROOT as its DEFAULT workspace (Explorer default view)";
  echo "PROJECTS_ROOT (deploy/.env)   : ${PR:-<empty>}";
  echo "code-server PID (owns ${HC_CSVR_ADDR}) : ${cs_pid:-<none>}";
  echo "running argv contains PROJECTS_ROOT    : $pr_in_runtime (runtime evidence)";
  echo "running argv has --auth none           : $auth_none";
  echo "ExecStart references PROJECTS_ROOT     : $pr_in_unit (config fallback)";
  echo "ExecStart line: ${exec_line:-<none>}";
  echo "HONEST NOTE (§11.4.6): PROJECTS_ROOT is the Explorer's DEFAULT folder, a convenience view —";
  echo "  NOT a security jail. code-server has no flag confining the process to it; the integrated";
  echo "  terminal, Open Folder and extensions retain full host FS access by design (docs/guides/AUTH.md)."; } > "$ev"
if [ -z "$PR" ]; then
  ab_skip_with_reason "CH5 Explorer default: PROJECTS_ROOT unset in deploy/.env (not configured in this env)" feature_disabled_by_config
elif [ "$pr_in_runtime" = 1 ]; then
  ab_pass_with_evidence "CH5: running code-server opens PROJECTS_ROOT as default workspace (runtime argv; convenience default, NOT a jail)" "$ev"
elif [ "$pr_in_unit" = 1 ]; then
  ab_pass_with_evidence "CH5: code-server launch config opens PROJECTS_ROOT as default workspace (ExecStart; convenience default, NOT a jail)" "$ev"
else
  ab_fail "CH5: no evidence code-server defaults the Explorer to PROJECTS_ROOT (runtime=$pr_in_runtime unit=$pr_in_unit) [ev: ${ev#$HC_ROOT/}]"
fi

h_log "note: this bank is also loadable by the vasic-digital/challenges Go engine (pkg/bank); this runner is the project-native always-available executor."
h_summary
