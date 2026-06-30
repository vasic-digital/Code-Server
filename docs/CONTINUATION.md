# CONTINUATION — HelixCode web-IDE platform

**Revision:** 2 · **Updated:** 2026-06-30 · **Status:** Phase 1 COMPLETE; Phase 2 CORE working+verified; P2-remaining + P3–7 PLANNED

**Phase 2 core (DONE, verified — `deploy/`):** Caddy edge + code-server stack boots
on Podman; `0.0.0.0:52443` (TLS1.3, openssl Verify=0) + `0.0.0.0:52080` (→301
HTTPS); code-server login HTML served (2621 B); `$PROJECTS` bind-mounted at
`/home/coder/projects/<name>`. Run via `deploy/up.sh` (parses `$PROJECTS`, podman
compose up). Client note: GnuTLS-curl can't handshake Caddy TLS1.3 (use browser/
openssl). P2-remaining: Open VSX mirror service, BuildKit warm image, generalize
into the `code_workspace` renderer.

Read FIRST on any fresh session: this file, then `git fetch --all`, then the spec
and plan below. This is the §12.10 / §11.4.131 standing resumption anchor.

## Where we are (live state — all pushed)

- **Main repo** `code_server` (= HelixCode): HEAD **`1284581`**, pushed to all 4
  upstreams (github vasic-digital/Code-Server, gitlab, gitflic, gitverse).
- **Constitution** pinned `674f830` (decoupled: project-derived workable-items
  key + release-prefix resolver + `.env`); pushed to all 6 constitution upstreams.
- **Owned submodules (8) at root**, all carry the Helix Constitution inheritance
  pointer (comprehensive test 16/0): `challenges, code_workspace, containers,
  docs_chain, helix_qa, helix_translate, port_prefix, vscode_profile_sync`
  (+ `constitution`). helix_translate pointer commit `6a6d909`.
- **3 NEW public reusable repos** created under vasic-digital on GitHub **and**
  GitLab, added as submodules:
  - `port_prefix` `b501b2b` — full lib (`Exposed(prefix,internalPort,taken)`),
    tests GREEN, §1.1 mutation (`scripts/mutation_check.sh`) PASS, CLI
    (`cmd/port_prefix`) verified (52xxx mapping).
  - `code_workspace` `5bd5146` — skeleton (pkg/workspace, go test ok).
  - `vscode_profile_sync` `6935a27` — skeleton (pkg/profile, go test ok).
- **Gates** in main: `tests/pre_build_verification.sh` (PASS), paired §1.1
  `scripts/testing/meta_test_false_positive_proof.sh` (PASS),
  `tests/test_constitution_inheritance.sh` (16/0).

## Source of truth

- Spec: `docs/superpowers/specs/2026-06-30-helixcode-platform-design.md`
- Plan: `docs/superpowers/plans/2026-06-30-helixcode-platform.md`
- Research evidence: scratchpad `…/research/0{1..4}_*.md` (web perf/UX, containers
  integration, QA integration, VSCode replication).

## Immediate NEXT — Phase 2 (`code_workspace` engine + compose stack)

Build in the `code_workspace` submodule (then have `code_server` consume it):
1. `pkg/compose`: render `compose.codeserver.yml` (services: caddy, code-server,
   openvsx-mirror) — ports from `port_prefix` (52443/52080/52808/52083),
   `$PROJECTS` bind mounts (`:Z`, `--userns=keep-id`, permissive). Golden-file test.
2. `entrypoint.sh`: parse `$PROJECTS` (colon-separated) → mounts + generated
   multi-root `.code-workspace`; tmux default shell; inotify/watcherExclude.
3. `Containerfile.codeserver` (FROM codercom/code-server) + BuildKit cache;
   `Caddyfile` (TLS mkcert/LE, HTTP/3, brotli, ws, rate-limit); openvsx-mirror
   (coder/code-marketplace).
4. Bring up LOCALLY via `containers` `pkg/compose` (`Up` build+wait) + health-gate
   via `pkg/endpoint`/`pkg/health`; verify 52443/52080 listen on `0.0.0.0`.
5. Remote deploy via `containers/cmd/deploy-stack`.
6. Paired mutation: break a health endpoint → health gate FAILS.
Acceptance: `curl -k https://0.0.0.0:52443` → code-server login; podman ps healthy.

Then P3 (profile sync), P4 (QA banks + autonomous), P5 (docs+SQL+DocsChain),
P6 (full validation with captured evidence), P7 (ship: push all + tag
`codeserver-1.0.0`).

## Binding constraints (every phase)

Port band **52000–52999** (≤65535); publish only edge/main ports on `0.0.0.0`;
no secrets (only git-ignored `.env`); **every gate paired with a §1.1 mutation**;
**no `--force`/`--no-verify`/bypass**; hardlinked `.git` backup before destructive
ops; **anti-bluff** (PASS needs captured runtime evidence); stop + root-cause +
full retest on any defect; release prefix `codeserver`; submodule commits
propagate first; docs kept in sync via Docs Chain.

## Known notes

- Agent fan-out has been hitting transient server rate-limits; mechanical build
  work is reliable done directly in the main stream.
- `helix_translate` deep-recursion is bounded by a stray `.claude/worktrees`
  gitlink in its OLD pinned constitution (`212b883`) — pre-existing, not ours.
- helix_qa already ships `banks/helixcode-*.yaml` targeting this IDE → P4 drives
  them via `helixqa http --banks helix_qa/banks --base-url https://localhost:52443`.
