#!/usr/bin/env bash
# tests/types/integration.sh — HelixCode INTEGRATION suite (§11.4.169 integration).
#
# Purpose:      Exercise the REAL, fully-wired stack — no mocks (§11.4.27(B)).
#               Boots infra on-demand via the fixture (§11.4.76) and asserts:
#                 (1) both containers (caddy + code-server) are running;
#                 (2) the TLS edge port is listening (real handshake / HTTP code);
#                 (3) the cs-data volume is seeded with settings.json carrying
#                     the watcherExclude fix, verified INSIDE the container;
#                 (4) the host Projects bind-mount is READ-WRITE inside the
#                     container — a uniquely-named token file is created, read
#                     back, and deleted, and the create->read->delete delta is
#                     confirmed (self-cleaning, single-owner-safe §11.4.119).
# Usage:        bash tests/types/integration.sh
# Inputs:       deploy/.env via the fixture (password never printed, §11.4.10)
# Outputs:      per-run evidence under qa-results/tests/integration/<run-id>/
# Side-effects: hc_stack_up may boot the stack; the RW probe file is deleted;
#               no data is ever destroyed and the shared stack is never stopped.
# Dependencies: bash, curl, podman|docker ; openssl (TLS probe)
# Cross-references: §11.4.76 §11.4.119 §11.4.27 §11.4.69 ; harness.sh stack_fixture.sh
. "$(dirname "$0")/../lib/harness.sh"
. "$(dirname "$0")/../lib/stack_fixture.sh"
h_init integration

# §11.4.1 / §11.4.90 — SUPERSEDED. This suite validates the RETIRED containerized
# code-server + CODE_SERVER_PASSWORD model; on the 2026-07-01 host-native SSH-key
# auth-pivot stack it is superseded by e2e_auth + security_auth. The old model is
# absent, so its assertions would FALSE-FAIL — SKIP-with-reason (evidence-based
# detection §11.4.6), never a false FAIL. On the OLD stack it still runs unchanged.
if hc_legacy_model_retired; then
  ab_skip_with_reason "integration suite: superseded by e2e_auth + security_auth — legacy container+password model retired (see docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md)" topology_unsupported
  h_summary; exit $?
fi

# ---- on-demand infra (§11.4.76) ------------------------------------------
if ! h_require podman && ! h_require docker; then
  ab_skip_with_reason "integration suite (no container runtime on PATH)" topology_unsupported
  h_summary; exit $?
fi
if ! hc_stack_up; then
  ab_fail "hc_stack_up: stack not reachable and on-demand boot failed (§11.4.76)"
  h_summary; exit $?
fi

# --------------------------------------------------------------------------
# (1) both containers running
# --------------------------------------------------------------------------
h_head "both stack containers running"
ev="$(h_ev containers_up)"
"$HC_ENGINE" ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null > "$ev"
cs_up="$(grep -c "^${HC_CS}[[:space:]]"    "$ev")"
cd_up="$(grep -c "^${HC_CADDY}[[:space:]]" "$ev")"
{ echo "expect: $HC_CS + $HC_CADDY running"; echo "code-server_present=$cs_up caddy_present=$cd_up"; } >> "$ev"
if [ "$cs_up" -ge 1 ] && [ "$cd_up" -ge 1 ]; then
  ab_pass_with_evidence "caddy + code-server containers are both Up" "$ev"
else ab_fail "expected both containers Up (cs=$cs_up caddy=$cd_up) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (2) TLS edge port listening (real HTTPS + handshake)
# --------------------------------------------------------------------------
h_head "TLS edge listening on ${HC_HTTPS}"
ev="$(h_ev tls_edge)"
code="$(hc_https_code /healthz)"
{ echo "GET https://127.0.0.1:${HC_HTTPS}/healthz -> $code"; echo "--- openssl s_client summary ---"; } > "$ev"
hc_tls_probe /dev/stdout >> "$ev" 2>&1 || true
if [ "$code" != 000 ] && grep -qiE 'protocol|cipher' "$ev"; then
  ab_pass_with_evidence "TLS edge on ${HC_HTTPS} answered (/healthz=$code) with a negotiated cipher" "$ev"
else ab_fail "TLS edge not listening/negotiating (code=$code) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (3) cs-data volume seeded with settings.json (verified inside container)
# --------------------------------------------------------------------------
h_head "cs-data volume seeded with watcherExclude settings (in-container)"
ev="$(h_ev cs_settings)"
SETPATH="/home/coder/.local/share/code-server/User/settings.json"
{ echo "in-container path: $SETPATH"
  echo "--- stat ---"; hc_cs_exec "ls -l '$SETPATH' 2>&1 || echo ABSENT"
  echo "--- watcherExclude grep ---"; hc_cs_exec "grep -c watcherExclude '$SETPATH' 2>/dev/null || echo 0"
  echo "--- sample excluded patterns present ---"
  hc_cs_exec "grep -oE 'node_modules|__pycache__|\\.gradle|prebuilts' '$SETPATH' 2>/dev/null | sort -u"
} > "$ev"
have_watch="$(hc_cs_exec "grep -c watcherExclude '$SETPATH' 2>/dev/null || echo 0" | tr -dc '0-9')"
have_nm="$(hc_cs_exec "grep -c node_modules '$SETPATH' 2>/dev/null || echo 0" | tr -dc '0-9')"
if [ "${have_watch:-0}" -ge 1 ] && [ "${have_nm:-0}" -ge 1 ]; then
  ab_pass_with_evidence "cs-data settings.json seeded in-container with watcherExclude + node_modules pattern" "$ev"
else ab_fail "in-container settings.json missing/unseeded (watch=$have_watch nm=$have_nm) [ev: ${ev#$HC_ROOT/}]"; fi

# --------------------------------------------------------------------------
# (4) host Projects bind-mount is READ-WRITE inside the container
#     write -> read -> delete a unique token; confirm the delta. Self-cleaning.
# --------------------------------------------------------------------------
h_head "project bind-mount is read-write (create/read/delete delta)"
ev="$(h_ev project_rw)"
# resolve the first mounted project dir inside the container.
PROJ_DIR="$(hc_cs_exec 'ls -1d /home/coder/projects/*/ 2>/dev/null | head -1' | tr -d '\r')"
if [ -z "$PROJ_DIR" ]; then
  { echo "no project mounted under /home/coder/projects"; } > "$ev"
  ab_skip_with_reason "project RW probe (no project mounted; deploy/.env PROJECTS empty)" feature_disabled_by_config
else
  tok="hc_int_rw_${H_RUNID}_$RANDOM"
  content="helixcode-rw-${tok}"
  f="${PROJ_DIR%/}/.$tok"
  # one exec: create, read back, delete, verify absence. rm always runs.
  result="$(hc_cs_exec "f='$f'; printf '%s' '$content' > \"\$f\" && rd=\$(cat \"\$f\" 2>/dev/null); rm -f \"\$f\"; if [ -e \"\$f\" ]; then gone=NO; else gone=YES; fi; echo \"READBACK=\$rd|GONE=\$gone\"")"
  { echo "project dir (in container): $PROJ_DIR"
    echo "token file: $f"
    echo "written content: $content"
    echo "exec result: $result"; } > "$ev"
  rb="$(printf '%s' "$result" | sed -nE 's/.*READBACK=([^|]*)\|.*/\1/p')"
  gone="$(printf '%s' "$result" | sed -nE 's/.*GONE=([A-Z]*).*/\1/p')"
  if [ "$rb" = "$content" ] && [ "$gone" = YES ]; then
    ab_pass_with_evidence "project mount RW proven: token written, read-back matched, deleted (delta confirmed)" "$ev"
  else ab_fail "project mount RW probe failed (readback='$rb' gone='$gone') [ev: ${ev#$HC_ROOT/}]"; fi
fi

h_summary
