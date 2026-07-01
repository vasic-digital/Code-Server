# codeserver-1.0.0-dev-0.0.2

**Revision:** 1 · **Last modified:** 2026-07-01T00:00:00Z

Second dev pre-release of **HelixCode**. This round adds (1) **Let's Encrypt
HTTPS with automatic renewal + full rotation**, and (2) **comprehensive
§11.4.169 test-type coverage** (14 suites) with rock-solid captured evidence,
then installs to the host and validates the whole stack live.

## Highlights

### Let's Encrypt HTTPS — auto-renewal + full rotation
- `deploy/up.sh` is now **`TLS_MODE`-aware**, rendering `deploy/Caddyfile` per
  mode: `self-signed` (default, LAN — **byte-identical** to the previous
  Caddyfile, regression-proven), `letsencrypt`, `letsencrypt-staging`,
  `internal-acme`.
- Config knobs in `deploy/.env.example` (placeholders only, no secrets):
  `TLS_MODE`, `CS_DOMAIN`, `ACME_EMAIL`, `ACME_CA_URL`, `ACME_CA_ROOT`,
  `ACME_DNS_PROVIDER`, `ACME_DNS_API_TOKEN`.
- Caddy performs ACME issuance + **~30-day-pre-expiry auto-renewal**; ACME
  account + certs persist in the `caddy-data` volume, so renewal + rotation
  **survive restart and reboot**.
- **Anti-bluff proof (§11.4.69/§11.4.123):** the full ACME issue→serve→**rotate**
  flow is proven end-to-end against a **local Pebble ACME CA** (rootless, its own
  ephemeral compose project) — leaf issued by `CN=Pebble Intermediate CA`, and
  cert **rotation confirmed** by serial change across independent runs. No public
  domain required for the proof.
- **Honest boundary (§11.4.6):** *real, publicly-trusted* Let's Encrypt issuance
  is operator-gated — it needs a public `CS_DOMAIN` resolving to the host with
  reachable `:80`/`:443`, **or** a DNS-01 provider token (this is a LAN box).
  Documented in `docs/guides/TLS.md`; the machinery + auto-renewal are wired and
  proven, only the public-CA step is yours to enable.

### Comprehensive §11.4.169 test-type coverage (14 suites)
New anti-bluff harness (`tests/lib/harness.sh` — every PASS must cite a
non-empty captured evidence file, or it converts to FAIL) + fixture
(`tests/lib/stack_fixture.sh` — on-demand stack boot §11.4.76) + aggregating
runner (`tests/run_all_types.sh`, risk-descending §11.4.132). Suites under
`tests/types/`:

| Suite | Covers |
|---|---|
| `unit` | tooling logic (port validation, atomic `.env`, settings JSON, TLS-mode select) |
| `integration` | real stack: containers Up, TLS edge, cs-data seeded, project RW in-container |
| `e2e` | full login journey (correct→302+cookie, wrong→200+no-cookie), authed editor |
| `full_automation` | autonomous, re-runnable, N=3 identical verdicts (§11.4.98/§11.4.50) |
| `security` | auth-required, TLS-enforced, no secret leak (§11.4.10), rootless (§11.4.161) |
| `load` | DDoS-class flood resilience, p50/p95 latency captured, graceful |
| `stress_chaos` | kill-code-server→502→recover, seed recovery, fd/conn pressure (§11.4.85) |
| `concurrency` | concurrent logins, atomic `.env` rewrite, idempotent start |
| `race` | no-deadlock concurrent probes + shellcheck error-class floor |
| `memory` | RSS soak bounded, host < 60% (§12.6) |
| `benchmark` | p50/p95/p99 login + authed op vs recorded baseline |
| `tls_letsencrypt` | TLS-mode machinery + local-CA issuance/rotation proof |
| `challenges` | anti-bluff capability Challenge bank (§11.4.27(B)) — TLS/auth/RW/watcher/TLS-mode |
| `helixqa` | autonomous QA bank journeys; in-browser UI honestly `operator_attended` (§11.4.52) |

Two defects were found by the matrix itself and fixed at root cause (§11.4.4):
- `scripts/set-password.sh` `.env` rewrite made **atomic** (temp+rename) — an
  interrupted write can no longer tear the live config (§11.4.6).
- `tests/types/integration.sh` SC1087 (variable-brace) + two `grep -c … || echo 0`
  double-count bugs (§11.4.1 FAIL-bluff) fixed.

`tests/types/unit.sh` (fast, stack-free) is wired into `tests/pre_build_verification.sh`
as a standing regression guard (§11.4.135); the full 14-suite matrix is the
§11.4.40 release gate.

### Live install + validation
`scripts/install.sh` re-run on the host (doctor → configure → start → boot
service): fresh stack Up, boot-survival service **enabled + linger**, then the
full 14-suite matrix run **live against the freshly-installed stack** (§11.4.108
clean-deployment).

## Validation (anti-bluff, §11.4)
- Full §11.4.169 matrix, run **live on the freshly-installed host**:
  **AGGREGATE PASS=14 FAIL=0** (14 suites, ~59 positive-evidence assertions,
  3 honest SKIPs). Evidence: `docs/qa/codeserver-1.0.0-dev-0.0.2/live-validation.md`.
- Local ACME issuance + rotation proven (Pebble); self-signed render
  byte-identical to committed Caddyfile.
- Stack healthy through chaos (kill→recover), memory < 60%, secrets never
  tracked/printed.

## Known / deferred
- Real public Let's Encrypt issuance is operator-gated (public domain + reachable
  ports, or a DNS-01 token) — see `docs/guides/TLS.md`.
- In-browser editor UI interaction (HC-QA-UI-001) is `operator_attended` pending
  a browser-automation adapter (tracked).
- Host inotify sysctl raise remains an optional `sudo scripts/tune-host.sh`
  (watcherExclude already keeps the tree under the limit).
