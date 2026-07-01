#!/usr/bin/env bash
#
# tests/types/tls_letsencrypt.sh — ANTI-BLUFF proof of HelixCode Let's Encrypt /
# ACME HTTPS with automatic renewal + rotation.
#
# §11.4.69 FEATURE: network_connectivity (edge TLS issuance/serving/rotation)
#
# Two layers (§11.4.108 source -> runtime):
#   Layer A (always, static/source): up.sh is TLS_MODE-aware, the self-signed
#     path is byte-for-byte unchanged (regression-safe), .env.example documents
#     the knobs, caddy-data persists ACME renewal state, the DNS-01 secret is
#     never baked into the tracked Caddyfile. Each PASS cites a captured file.
#   Layer B (real ACME): drives deploy/acme/run.sh — a local Pebble CA proves the
#     FULL ACME flow: Caddy OBTAINS a CA-signed leaf, SERVES it, and ROTATES it
#     to a NEW cert (different serial). Rock-solid captured evidence (issuer +
#     serials + chain). If Pebble/Caddy images are unpullable (no network) it is
#     an HONEST SKIP (network_unreachable_external) — never a faked PASS.
#
# Re-runnable + self-cleaning (§11.4.98): deploy/acme/run.sh tears its ephemeral
# project down in a trap EXIT; this suite writes fresh evidence per run.
#
# ── PAIRED §1.1 MUTATIONS (what makes each assertion genuinely FAIL) ──────────
#   A1 self-signed byte-identity : change one byte in up.sh render_selfsigned()
#      -> cmp vs committed deploy/Caddyfile differs -> A1 FAILs.
#   A2 TLS_MODE dispatch present  : delete the `case "$TLS_MODE"` block in up.sh
#      -> grep finds no dispatch  -> A2 FAILs.
#   A3 internal-acme acme_ca      : drop the `acme_ca` line from render_acme()
#      -> rendered internal-acme config lacks acme_ca -> A3 FAILs.
#   A6 DNS-01 no-secret-bake      : make render_acme() substitute the literal
#      token instead of {env.ACME_DNS_API_TOKEN} -> token appears in file ->
#      A6 FAILs (also a §11.4.10 leak).
#   B  ACME issuance/rotation     : in deploy/acme/Caddyfile.edge remove the
#      `acme_ca {$ACME_CA_URL}` line -> Caddy uses its INTERNAL issuer, served
#      leaf issuer is "Caddy Local Authority" (not Pebble) -> run.sh's issuer
#      check never matches -> run.sh exits 1 -> Layer B FAILs.
#      Rotation half: delete the `rm -rf /data/caddy/certificates` line in
#      run.sh -> serial2 == serial1 -> run.sh's rotation assert FAILs.
#
# Cross-refs: §11.4.5 §11.4.69 §11.4.98 §11.4.108 §11.4.115 §11.4.123 §1.1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/harness.sh"
. "$HERE/../lib/stack_fixture.sh"

h_init tls_letsencrypt
DEP="$HC_ROOT/deploy"

# §11.4.1 / §11.4.90 — SUPERSEDED. Layer A asserts byte-identity of the OLD
# compose/up.sh/Caddyfile deploy render (reverse_proxy code-server:8080) and Layer B
# drives the old containerized ACME flow — both belong to the RETIRED containerized
# code-server + password model. The 2026-07-01 host-native SSH-key auth-pivot stack
# reworked the deploy topology (Caddy edge -> forward_auth -> host-native gate); TLS
# for the new edge is exercised by the *_auth suites. Its assertions would now
# FALSE-FAIL, so SKIP-with-reason (§11.4.6 detection). Old stack still runs it.
if hc_legacy_model_retired; then
  ab_skip_with_reason "tls_letsencrypt suite: superseded by the *_auth suites (host-native TLS edge) — legacy container+password deploy model retired (see docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md)" topology_unsupported
  h_summary; exit $?
fi

# ===========================================================================
# Layer A — source/static, always runs
# ===========================================================================
h_head "Layer A: TLS_MODE-aware up.sh + regression-safe self-signed + docs"

# A1: self-signed render is BYTE-IDENTICAL to the committed Caddyfile.
ev="$(h_ev A1_selfsigned_byte_identity)"
tmpcfg="$HC_EV_DIR/rendered_selfsigned.caddyfile"
( cd "$DEP" && UP_SH_RENDER_ONLY=1 CADDYFILE_OUT="$tmpcfg" TLS_MODE=self-signed PORT_PREFIX=52 \
    bash up.sh ) >/dev/null 2>&1 || true
{
  echo "assert: up.sh self-signed render == committed deploy/Caddyfile (regression-safe)"
  if [ -f "$tmpcfg" ] && cmp -s "$tmpcfg" "$DEP/Caddyfile"; then
    echo "RESULT: BYTE-IDENTICAL"
  else
    echo "RESULT: DIFFER"; diff "$DEP/Caddyfile" "$tmpcfg" 2>&1 || true
  fi
} > "$ev"
if grep -q "BYTE-IDENTICAL" "$ev"; then
  ab_pass_with_evidence "self-signed Caddyfile render is byte-identical (no regression)" "$ev"
else
  ab_fail "self-signed render diverged from committed Caddyfile [ev: ${ev#$HC_ROOT/}]"
fi

# A2: up.sh actually dispatches on TLS_MODE (self-signed|letsencrypt|internal-acme).
ev="$(h_ev A2_tls_mode_dispatch)"
grep -nE 'TLS_MODE|letsencrypt|internal-acme|render_acme|render_selfsigned' "$DEP/up.sh" > "$ev" 2>&1 || true
if grep -q 'letsencrypt-staging' "$ev" && grep -q 'internal-acme' "$ev" && grep -q 'render_acme' "$ev"; then
  ab_pass_with_evidence "up.sh is TLS_MODE-aware (self-signed / letsencrypt* / internal-acme)" "$ev"
else
  ab_fail "up.sh missing TLS_MODE dispatch [ev: ${ev#$HC_ROOT/}]"
fi

# A3: internal-acme renders a real acme_ca site block for the domain.
ev="$(h_ev A3_internal_acme_render)"
iacfg="$HC_EV_DIR/rendered_internal_acme.caddyfile"
( cd "$DEP" && UP_SH_RENDER_ONLY=1 CADDYFILE_OUT="$iacfg" TLS_MODE=internal-acme \
    CS_DOMAIN=code.helixcode.test ACME_EMAIL=a@b.c ACME_CA_URL=https://pebble:14000/dir \
    bash up.sh ) >/dev/null 2>&1 || true
cp -f "$iacfg" "$ev" 2>/dev/null || echo "(render failed)" > "$ev"
if grep -q 'acme_ca https://pebble:14000/dir' "$ev" && grep -q '^code.helixcode.test {' "$ev" \
   && grep -q 'reverse_proxy code-server:8080' "$ev"; then
  ab_pass_with_evidence "internal-acme renders acme_ca + domain site + reverse_proxy" "$ev"
else
  ab_fail "internal-acme render incomplete [ev: ${ev#$HC_ROOT/}]"
fi

# A4: .env.example documents every TLS knob (no secrets present).
ev="$(h_ev A4_env_example_knobs)"
grep -nE 'TLS_MODE|CS_DOMAIN|ACME_EMAIL|ACME_CA_URL|ACME_DNS_PROVIDER|ACME_DNS_API_TOKEN' \
  "$DEP/.env.example" > "$ev" 2>&1 || true
missing=""
for k in TLS_MODE CS_DOMAIN ACME_EMAIL ACME_CA_URL ACME_DNS_PROVIDER ACME_DNS_API_TOKEN; do
  grep -q "$k" "$ev" || missing="$missing $k"
done
if [ -z "$missing" ]; then
  ab_pass_with_evidence ".env.example documents all TLS knobs" "$ev"
else
  ab_fail ".env.example missing knobs:$missing [ev: ${ev#$HC_ROOT/}]"
fi

# A5: caddy-data volume persists ACME renewal state across restart/reboot.
ev="$(h_ev A5_caddy_data_persisted)"
grep -nE 'caddy-data:/data|^  caddy-data:|caddy-data' "$DEP/compose.codeserver.yml" > "$ev" 2>&1 || true
if grep -q 'caddy-data:/data' "$ev"; then
  ab_pass_with_evidence "caddy-data:/data persisted (ACME account+certs survive restart)" "$ev"
else
  ab_fail "caddy-data /data mount missing — renewal state would not persist [ev: ${ev#$HC_ROOT/}]"
fi

# A6: DNS-01 secret is referenced as {env...}, NEVER baked into the tracked file.
ev="$(h_ev A6_dns01_no_secret_bake)"
dnscfg="$HC_EV_DIR/rendered_dns01.caddyfile"
( cd "$DEP" && UP_SH_RENDER_ONLY=1 CADDYFILE_OUT="$dnscfg" TLS_MODE=letsencrypt \
    CS_DOMAIN=code.example.com ACME_EMAIL=a@b.c ACME_DNS_PROVIDER=cloudflare \
    ACME_DNS_API_TOKEN=PROOF_TOKEN_SHOULD_NOT_APPEAR bash up.sh ) >/dev/null 2>&1 || true
{
  echo "rendered DNS-01 config (token must be absent, {env...} present):"
  cat "$dnscfg" 2>/dev/null
  echo "--- leak scan ---"
  if grep -q 'PROOF_TOKEN_SHOULD_NOT_APPEAR' "$dnscfg" 2>/dev/null; then echo "LEAK: token found"; else echo "NO-LEAK: token absent"; fi
} > "$ev"
if grep -q 'NO-LEAK: token absent' "$ev" && grep -q '{env.ACME_DNS_API_TOKEN}' "$dnscfg" 2>/dev/null; then
  ab_pass_with_evidence "DNS-01 token not baked into Caddyfile ({env...} ref only; §11.4.10)" "$ev"
else
  ab_fail "DNS-01 token leaked into rendered Caddyfile [ev: ${ev#$HC_ROOT/}]"
fi

# ===========================================================================
# Layer B — REAL ACME issuance + rotation via local Pebble CA
# ===========================================================================
h_head "Layer B: real ACME issuance + rotation (local Pebble CA)"

acme_sub="$HC_EV_DIR/acme_proof"
mkdir -p "$acme_sub"
runlog="$HC_EV_DIR/acme_run.log"

if ! h_require openssl; then
  ab_skip_with_reason "ACME proof (openssl absent)" "topology_unsupported"
else
  # RED_MODE=1 => run the harness with --keep so a debugger can inspect it; the
  # standing GREEN guard (RED_MODE=0) tears down.
  extra=""; [ "${RED_MODE:-0}" = 1 ] && extra="--keep"
  set +e
  bash "$DEP/acme/run.sh" --evidence-dir "$acme_sub" $extra > "$runlog" 2>&1
  rc=$?
  # (do NOT re-enable errexit: the harness runs with `set -uo pipefail` only)
  h_log "deploy/acme/run.sh exit=$rc (log: ${runlog#$HC_ROOT/})"

  case "$rc" in
    0)
      res="$acme_sub/acme_result.txt"
      s1="$(grep -m1 '^ACME_SERIAL_INITIAL=' "$runlog" | cut -d= -f2)"
      s2="$(grep -m1 '^ACME_SERIAL_ROTATED=' "$runlog" | cut -d= -f2)"
      # B1: leaf genuinely issued by Pebble (ACME), served over TLS.
      if grep -q 'ACME_ISSUER_MATCH=pebble' "$runlog" && [ -s "$res" ]; then
        ab_pass_with_evidence "Caddy obtained + served a Pebble-issued ACME leaf" "$res"
      else
        ab_fail "ACME issuance not confirmed [log: ${runlog#$HC_ROOT/}]"
      fi
      # B2: rotation produced a NEW cert (different serial), still Pebble-issued.
      rotev="$acme_sub/acme_rotation.txt"
      if [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ] && [ -s "$rotev" ]; then
        ab_pass_with_evidence "renewal rotated the cert ($s1 -> $s2)" "$rotev"
      else
        ab_fail "rotation did not change the serial (s1=$s1 s2=$s2) [ev: ${rotev#$HC_ROOT/}]"
      fi
      ;;
    2)
      ab_skip_with_reason "real ACME proof (Pebble/Caddy image unpullable)" "network_unreachable_external"
      ;;
    *)
      [ -s "$runlog" ] || echo "(run.sh produced no log)" > "$runlog"
      ab_fail "deploy/acme/run.sh FAILED rc=$rc [log: ${runlog#$HC_ROOT/}]"
      ;;
  esac
fi

h_summary
