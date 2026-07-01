# CONTINUATION — HelixCode web-IDE platform

**Revision:** 7 · **Updated:** 2026-07-02 · **Status:** `codeserver-1.0.0-dev-0.0.4` **RELEASED** (`0e2f854`, tag on all 4 mirrors, GitHub+GitLab prereleases). Release gate: full §11.4.169 matrix **29/29 suites PASS, 0 FAIL** (61 checks PASS, 24 honest SKIP; evidence `qa-results/run_all/20260701T222753Z-2813294`). **Post-release coverage promotion (§11.4.52/§11.4.123):** wiring an authorized `HELIX_TEST_SSH_KEY` (gitignored `deploy/.env`; §11.4.10 never committed/logged) promoted the ~10 `credential_absent` auth SKIPs into **real authenticated-session PASSes** — matrix re-run **29/29 suites PASS, 0 FAIL, 71 checks PASS / 17 SKIP** (evidence `qa-results/run_all/20260701T231807Z-3364116`); the 17 remaining SKIPs are all honest (11 legacy-suite `topology_unsupported` retirements, 2 `operator_attended` with passing CLI siblings, 2 Chromium-contended pixel proofs, **1 `credential_absent`** = C3's destructive cookie-secret interlock — deliberately NOT run autonomously against the live gate per §11.4.101, throwaway-gate variant tracked — and 1 `feature_disabled_by_config` = `load_auth` L3 login-flood rate-limit inconclusive, where the limiter is nonetheless positively confirmed by `security_auth` #4's real 429). Ships: login-redirect fix + login-form copy/paste clipboard buttons + Open VSX marketplace install/use/persist/config + popular extensions + VS Code Dark default theme (host-rendered pixel proof) + durable `systemd --user` edge. Three test-infra suites hardened against shared-host `ulimit -u` fork-pressure false-FAILs (§11.4.1/§11.4.3/§11.4.174) + independently reviewed to a clean GO (§11.4.142/§11.4.134). Stack LIVE at https://192.168.0.213:52443 (all `systemd --user`).

Read FIRST on any fresh session: this file, then `git fetch --all`, then the
auth-pivot spec + AUTH guide + feature ledger below. This is the §12.10 /
§11.4.131 standing resumption anchor.

## Current phase — `codeserver-1.0.0-dev-0.0.4` **RELEASED** (idle unless new operator request)

`codeserver-1.0.0-dev-0.0.4` is **RELEASED** (`0e2f854`): full §11.4.169
release-gate matrix **29/29 suites PASS, 0 FAIL** on the reviewed+hardened tree
(evidence `qa-results/run_all/20260701T222753Z-2813294`), tag pushed to all 4
mirrors (no force, §11.4.113), GitHub + GitLab prereleases created. The batch's
three hardened test-infra suites (`race`, `extensions_ui_auth`,
`extensions_popular_auth`) were fixed for shared-host `ulimit -u` fork-pressure
**environmental** false-FAILs (§11.4.1/§11.4.3/§11.4.174 — genuine defects still
FAIL, host starvation → SKIP-with-reason) and independently reviewed to a clean
GO (§11.4.142/§11.4.134; F1–F4 + N1 all resolved; every §1.1 mutation re-proven).

Prior: `codeserver-1.0.0-dev-0.0.3` **RELEASED** (`2746e0e`) — the real-account
SSH-key challenge-response auth model, §11.4.169 matrix 23/23 + Go gate 70 tests
`-race`. The dev-0.0.4 batch (login-redirect fix + copy/paste buttons + Open VSX
marketplace coverage + VS Code Dark default + durable edge + deep research)
landed across these commits toward the release:

- `75e2d9b` — login-redirect fix (an unauthenticated browser now lands on the
  login form instead of a bodyless "This page isn't working").
- `e0519bf` — hardening: **DURABLE** `systemd` Quadlet edge that survives session
  crashes + full-host reboot, tarball code-server install (drops the fragile npm
  path), loopback:8080 host-firewall rule, doc exports.
- `43e37a5` — `extensions_auth` suite **5/5** (Open VSX plugin install + use,
  anti-bluff).
- `eee6169` — feature ledger reconciled to real evidence (`docs/features/Status.md`
  + `Status_Summary.md`).
- `849dc9a` — extensions (marketplace) guide + read-only gallery probe.
- `8351e4c` — login-form copy/paste clipboard buttons **3/3** + UI-driven
  marketplace test.
- `97a8c69` — VS Code Dark **default** theme (+ pixel proof) + popular-extensions
  install/use/persist + auth-modernization deep-research report.

The stack is LIVE + reachable at **https://192.168.0.213:52443** — every component
is `systemd --user`-managed (Caddy edge Quadlet, `helix-auth`,
`helix-code-server`). All standing operator requests have landed: extension
install/use tests, login-form copy/paste buttons, popular-extensions
install/use/persist, VS Code Dark default, and the first deep-research report.

- Changelog (in progress): `docs/changelogs/codeserver-1.0.0-dev-0.0.4.md`
- Prior release: `docs/changelogs/codeserver-1.0.0-dev-0.0.3.md`
- Auth pivot spec (authoritative): `docs/superpowers/specs/2026-07-01-auth-pivot-ssh-key.md`
- Extensions guide: `docs/guides/EXTENSIONS.md` · Edge boot: `docs/guides/EDGE_BOOT.md`
- User guide: `docs/guides/AUTH.md` · Feature ledger: `docs/features/Status.md`
- Deep-research (standing directive): `docs/research/auth_modernization_20260701/FINDINGS.md`
  (first report → **WebAuthn/passkeys recommended**)

### Why the pivot (captured facts, §11.4.6)

This host is ALT Linux with the **tcb** shadow scheme, so a **non-root** service
cannot verify passwords via PAM (`/etc/tcb/<user>/shadow` unreadable by the user;
`tcb_chkpwd` setuid helper permission-denied to non-root ⇒ `pam_authenticate`
returns `PAM_AUTH_ERR` for every password). A password gate would need root; the
operator directive is **no sudo/root** and **all access via SSH keys**.
`~/.ssh/authorized_keys` is readable and `ssh-keygen -Y sign`/`-Y verify` are
supported, so SSH-key challenge-response runs fully **as non-root milosvasic**,
with **no password and nothing stored**.

## Architecture (this release)

```
Browser ──HTTPS──▶ Caddy (TLS edge, CONTAINERIZED rootless Podman; HTTP/3 + brotli via custom xcaddy)
                    ├─ forward_auth ─▶ helix-auth (host-native Gin, systemd --user, loopback:8081, NON-root)
                    └─ reverse_proxy ─▶ code-server (host-native AS milosvasic, systemd --user,
                                          --auth none, loopback:8080; inherits ~/.ssh, ~/.bashrc, host binaries)
```

- **code-server** — host-native `systemd --user`, `--auth none`, loopback:8080.
- **helix-auth** — host-native **Gin** gate, `systemd --user`, loopback:8081,
  non-root: SSH-key challenge (`GET /login`) → verify pasted signature vs
  `authorized_keys` (`ssh-keygen -Y verify`) → `__Host-` session cookie; `GET /auth`
  for forward_auth; **fails closed**.
- **Caddy** — sole containerized component: TLS edge, `forward_auth` (fail-closed),
  HTTP/3, `encode zstd br gzip`, `/proxy` 403, `X-Helix-User` strip.
- **Stack directive adopted:** Go + Gin + HTTP/3 (QUIC) + Brotli.

## Feature status (§11.4.6 — honest)

The real-account + SSH-key rows in `docs/features/Status.md` are **PASS with cited
captured evidence** (§11.4.169 matrix 23/23 PASS; Status.md Revision 2). Testing:
Go unit/integration/race (**70 tests, `-race`, 81.8% cover**) + shell suites
`tests/types/{e2e,security,stress_chaos,concurrency,load,memory,benchmark,challenges,helixqa}_auth.sh`
+ banks `tests/banks/helixcode-auth-{challenges,helixqa}.yaml`. The live aggregate
is the conductor-filled placeholder in the changelog.

### Honest boundaries carried into the release

- Editor "jail" is **cosmetic** (Explorer default only; terminal/Open-Folder/
  extensions keep full host access by design).
- `--auth none` on loopback:8080 is a **residual** — host firewall rule for
  loopback:8080 recommended (all real auth is at the gate/edge).
- code-server pinned **4.117.0** (newest on npm at release time).
- Real public Let's Encrypt remains **operator-gated** (see `docs/guides/TLS.md`).

## Migration

`scripts/install-auth.sh` (host-native, **no sudo**) provisions the `systemd --user`
code-server + helix-auth units; `deploy/up.sh` brings up the Caddy edge.
**`CODE_SERVER_PASSWORD` is retired** → `HELIX_AUTH_MODE=sshkey`,
`HELIX_AUTH_ACCOUNT`, `HELIX_AUTH_AUTHORIZED_KEYS`, `HELIX_AUTH_PRINCIPAL`,
`PROJECTS_ROOT` (no password parameter).

## Immediate NEXT (post-release — idle per §11.4.126 unless a new operator request)

`codeserver-1.0.0-dev-0.0.4` is RELEASED + published everywhere; the post-release
credential-coverage promotion (above) is landed and matrix-proven. Open follow-ups
(non-blocking, no new operator request required to be idle):

1. **C3 throwaway-gate variant** — stand up an isolated throwaway `helix-auth`
   instance so `stress_chaos_auth` C3 (cookie-secret rotation → session
   invalidation) runs autonomously + non-destructively, promoting its last
   `credential_absent` SKIP (§11.4.52/§11.4.85). It is deliberately NOT run against
   the LIVE gate (rotating the live secret logs out the operator's session,
   §11.4.101). Tracked.
2. **(Optional) harness auto-resolve of an authorized key** — make real auth
   coverage the out-of-the-box default even without `deploy/.env` wiring (scan
   `~/.ssh` for a key whose `.pub` is in the gate's authorized_keys; honest SKIP if
   none). Needs the full review gauntlet + a paired §1.1 mutation; not required
   (the `deploy/.env` wiring already closes the gap durably on this host).
3. Standing operator directive — **frequent deep research** (§11.4.150): keep
   producing reports; the first landed report recommends **WebAuthn/passkeys** as
   the auth-modernization path
   (`docs/research/auth_modernization_20260701/FINDINGS.md`); the passkey-login
   spec at `docs/superpowers/specs/2026-07-01-webauthn-passkey-login.md` is drafted,
   NOT implemented, awaiting an operator decision.

## Binding constraints (every phase)

Port band **52000–52999**; publish only edge ports on `0.0.0.0`; **no secrets**
(only git-ignored `.env`); **every gate paired with a §1.1 mutation**; **no
`--force`/`--no-verify`/bypass**; hardlinked `.git` backup before destructive ops;
**anti-bluff** (PASS needs captured runtime evidence, no invented numbers); stop +
root-cause + full retest on any defect; release prefix `codeserver`; submodule
commits propagate first; docs kept in sync.

## Prior state (Phases 1–2, retained)

Phase 1 COMPLETE; Phase 2 core working+verified (Caddy edge + code-server stack on
Podman; TLS1.3 edge on 52443, →301 on 52080; `$PROJECTS` bind-mounted). Owned
submodules (8) at root carry the Constitution inheritance pointer; constitution
pinned (see history). Prior release `codeserver-1.0.0-dev-0.0.2` shipped Let's
Encrypt HTTPS (auto-renew + rotation) + the 14-suite §11.4.169 matrix.
