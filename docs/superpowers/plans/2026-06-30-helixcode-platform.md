# HelixCode Web-IDE Platform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a fully containerized, network-exposed browser VSCode (code-server) that exposes `$PROJECTS` with permissive perms and replicates the host VSCode profile, built by maximally reusing Helix submodules and three new reusable public submodules.

**Architecture:** One Podman/Docker compose stack (Caddy edge → code-server → self-hosted Open VSX mirror), orchestrated via the `containers` submodule; host projects bind-mounted; profile reproduced via `vscode_profile_sync`; ports mapped by `port_prefix`; QA via `challenges`+`helix_qa`; docs/SQL synced by `docs_chain`.

**Tech Stack:** Go (reusable submodule libs), bash entrypoints, Podman/Docker compose, Caddy, coder/code-server, coder/code-marketplace, SQLite, Mermaid/PlantUML.

## Global Constraints

- Port prefix `52` → every EXPOSED host port in **52000–52999** (≤65535), authoritative table in spec §3.
- Services publish on `0.0.0.0`; internal services stay on the compose network.
- New shared submodules: **PUBLIC**, snake_case, zero project-specific names/keys, constitution inheritance pointer, multi-upstream `upstreams/`, 4-layer tests.
- No secrets/PII anywhere; secrets only in git-ignored `.env`; tracked `.env.example` placeholders only.
- Every gate paired with a §1.1 mutation that MUST fail on a broken target.
- No `--force`/`--no-verify`/bypass; hardlinked `.git` backup before destructive ops.
- Anti-bluff: every PASS carries positive runtime evidence; stop + root-cause + full retest on any discovered defect.
- Release tag prefix `codeserver` (`.env` `HELIX_RELEASE_PREFIX`).

---

## Phase index (each phase = its own working, testable deliverable)

| Phase | Deliverable | Reuses | New submodule | Detailed plan |
|---|---|---|---|---|
| **P1** | 3 public repos created + `port_prefix` lib built + all 3 added as submodules | gh, glab | port_prefix, code_workspace(skel), vscode_profile_sync(skel) | **this doc, below** |
| P2 | `code_workspace` engine + `compose.codeserver.yml` + entrypoint; stack boots locally on 52xxx | containers | code_workspace | `…-p2-code-workspace.md` |
| P3 | `vscode_profile_sync`: extract host profile → reproduce in code-server (12 OpenVSX + 2 VSIX), theme parity | — | vscode_profile_sync | `…-p3-profile-sync.md` |
| P4 | QA: code-server challenge bank + drive helixcode banks + autonomous web session; 15 test types; paired mutations | challenges, helix_qa | — | `…-p4-qa.md` |
| P5 | Docs + diagrams + SQL schema + Docs-Chain registration + hooks | docs_chain | — | `…-p5-docs.md` |
| P6 | Full validation: real boot + real client + autonomous QA GREEN with captured evidence | all | — | `…-p6-validate.md` |
| P7 | Commit + push every submodule + main to all upstreams; tag `codeserver-1.0.0` | — | — | `…-p7-ship.md` |

---

# PHASE 1 — Bootstrap submodules + `port_prefix` (fully detailed)

### Task 1.1: Create the three public repos (GitHub + GitLab)

**Files:** none (remote infra). **Interfaces produces:** the 6 remote repos the later tasks add as submodules.

- [ ] **Step 1: Pre-check access + non-existence** (no guessing)

```bash
for n in code_workspace vscode_profile_sync port_prefix; do
  echo "== $n =="
  gh repo view "vasic-digital/$n" >/dev/null 2>&1 && echo "GH EXISTS" || echo "GH free"
  glab repo view "vasic-digital/$n" >/dev/null 2>&1 && echo "GL EXISTS" || echo "GL free"
done
```
Expected: all "free" (if any EXISTS, STOP and report — do not clobber).

- [ ] **Step 2: Create the GitHub repos (public, with description)**

```bash
gh repo create vasic-digital/port_prefix       --public -d "Deterministic prefixed-port mapping (<=65535, collision-resolved) — reusable" || echo FAIL
gh repo create vasic-digital/code_workspace     --public -d "Generic containerized browser-IDE orchestration engine — reusable" || echo FAIL
gh repo create vasic-digital/vscode_profile_sync --public -d "Extract a desktop VSCode profile and reproduce it in code-server — reusable" || echo FAIL
```
Expected: each prints the created repo URL. If a create FAILS (perms/policy), STOP and report the exact error — do not retry blindly.

- [ ] **Step 3: Create the GitLab mirrors (public)**

```bash
for n in port_prefix code_workspace vscode_profile_sync; do
  glab repo create "vasic-digital/$n" --public 2>&1 | tail -2 || echo "FAIL $n"
done
```
Expected: each created. Report any failure verbatim.

- [ ] **Step 4: Verify reachability**

```bash
for n in port_prefix code_workspace vscode_profile_sync; do
  git ls-remote "git@github.com:vasic-digital/$n.git" >/dev/null 2>&1 && echo "GH ok $n" || echo "GH MISS $n"
  git ls-remote "git@gitlab.com:vasic-digital/$n.git" >/dev/null 2>&1 && echo "GL ok $n" || echo "GL MISS $n"
done
```
Expected: all ok. (Empty repos return ok with no refs — that's fine.)

### Task 1.2: Build `port_prefix` (Go lib + CLI, TDD)

**Files:**
- Create: `port_prefix/go.mod` (`module github.com/vasic-digital/port_prefix`, go 1.23)
- Create: `port_prefix/prefix.go` (mapping core)
- Test: `port_prefix/prefix_test.go`
- Create: `port_prefix/cmd/port_prefix/main.go` (CLI: prints table / compose ports lines)
- Create: `port_prefix/upstreams/{GitHub,GitLab}.sh`, `port_prefix/.gitignore`, `port_prefix/README.md`, `port_prefix/CLAUDE.md`, `port_prefix/AGENTS.md` (constitution inheritance pointer — prepend the nested pointer block)

**Interfaces produces:**
- `func Map(prefix int, ports []int) ([]Mapping, error)` where `type Mapping struct{ Service string; Internal, Exposed int }` — but service-less form: `func Exposed(prefix, internalPort int, taken map[int]bool) (int, error)` returns a port in `[prefix*1000, prefix*1000+999]`, ≤65535, not in `taken`; deterministic: tries `prefix*1000 + (internalPort % 1000)` then linear-probes; errors if the whole band is exhausted or `prefix*1000+999 > 65535`.

- [ ] **Step 1: Write the failing test**

```go
package portprefix
import "testing"
func TestExposed_basic(t *testing.T) {
    taken := map[int]bool{}
    got, err := Exposed(52, 443, taken)      // 52*1000 + 443 = 52443
    if err != nil || got != 52443 { t.Fatalf("443 -> %d,%v want 52443", got, err) }
    taken[got] = true
    got, err = Exposed(52, 8080, taken)       // 8080%1000=80 -> 52080
    if err != nil || got != 52080 { t.Fatalf("8080 -> %d,%v want 52080", got, err) }
    taken[got] = true
    got, _ = Exposed(52, 80, taken)           // 80 -> 52080 taken -> probe 52081
    if got != 52081 { t.Fatalf("80 collision -> %d want 52081", got) }
}
func TestExposed_overflow(t *testing.T) {
    if _, err := Exposed(99, 999, map[int]bool{}); err == nil { // 99*1000+999=99999 > 65535
        t.Fatal("want overflow error for prefix 99")
    }
}
```

- [ ] **Step 2: Run test, verify it fails**
Run: `cd port_prefix && go test ./...`  Expected: FAIL (undefined: Exposed).

- [ ] **Step 3: Implement minimal code**

```go
package portprefix
import "fmt"
func Exposed(prefix, internalPort int, taken map[int]bool) (int, error) {
    base := prefix * 1000
    if base+999 > 65535 { return 0, fmt.Errorf("prefix %d band exceeds 65535", prefix) }
    start := base + (internalPort % 1000)
    for p := start; p <= base+999; p++ { if !taken[p] { return p, nil } }
    for p := base; p < start; p++ { if !taken[p] { return p, nil } }
    return 0, fmt.Errorf("prefix %d band 52000-52999 exhausted", prefix)
}
```

- [ ] **Step 4: Run tests, verify pass**
Run: `cd port_prefix && go test ./...`  Expected: PASS (ok).

- [ ] **Step 5: Add the CLI + scaffolding files** (constitution pointer prepended to CLAUDE.md/AGENTS.md; `upstreams/GitHub.sh` exports `UPSTREAMABLE_REPOSITORY="git@github.com:vasic-digital/port_prefix.git"`, GitLab analog; README documents the band rule + the §3 table).

- [ ] **Step 6: §1.1 paired mutation** — `port_prefix/scripts/mutation_check.sh`: temporarily break the overflow guard (`base+999 > 65535` → `false`), run `go test`, assert it now FAILS, restore. Wire a gate `make verify` that runs `go test ./...`; the mutation proves the test catches the regression.

- [ ] **Step 7: Commit + push to both upstreams** (configure via `bash install_upstreams.sh` copied from constitution, or set remotes manually; `git push origin main` fan-out). No force.

### Task 1.3: Scaffold `code_workspace` + `vscode_profile_sync` skeletons

**Files (each repo):** `go.mod`, `README.md`, `ARCHITECTURE.md`, `CLAUDE.md`+`AGENTS.md` (constitution pointer), `upstreams/{GitHub,GitLab}.sh`, `.gitignore`, `.env.example`, a stub package + a placeholder passing test (`TestPlaceholder`), `Makefile` (`verify` target).

- [ ] Steps: create files; `go test ./...` PASS (placeholder); commit + push both upstreams. (Full implementation lands in P2/P3.)

### Task 1.4: Add the three repos as submodules of the main repo

**Files:** Modify `.gitmodules`; create `port_prefix/`, `code_workspace/`, `vscode_profile_sync/` gitlinks.

- [ ] **Step 1: Hardlink `.git` backup** (`cp -al .git ../.code_server_git_backups/repo.git.pre_newsubs.mirror`).
- [ ] **Step 2:** `git submodule add git@github.com:vasic-digital/port_prefix.git port_prefix` (repeat for the other two).
- [ ] **Step 3:** `git -C <each> bash install_upstreams.sh` (configure multi-upstream inside each submodule).
- [ ] **Step 4:** Run `bash tests/pre_build_verification.sh` (must still PASS) and `bash tests/test_constitution_inheritance.sh` (owned top-level now includes the 3 new ones — they carry the constitution pointer → PASS).
- [ ] **Step 5:** Commit main (`git add -A`) + push to all 4 upstreams. No force.

**Phase 1 acceptance:** 3 public repos exist on GH+GL; `port_prefix` `go test` green + paired mutation proven; all 3 added as submodules; main-repo gate + comprehensive test green; everything pushed.

---

# PHASE 2 — `code_workspace` engine + compose stack (task roadmap)

- **T2.1** `code_workspace/pkg/compose`: render `compose.codeserver.yml` from inputs (services: caddy, code-server, openvsx-mirror; ports from `port_prefix`; `$PROJECTS` bind mounts with `:Z`+keep-id). TDD: golden-file test of rendered YAML.
- **T2.2** `code_workspace/entrypoint.sh`: parse `$PROJECTS` → mounts + generated `.code-workspace`; tmux default shell; inotify/watcherExclude. TDD: bats/shell test with a fake PROJECTS.
- **T2.3** `Containerfile.codeserver` (FROM codercom/code-server) + BuildKit cache mounts; Caddyfile (TLS mkcert/LE, HTTP/3, brotli, ws, rate-limit); openvsx-mirror service (coder/code-marketplace).
- **T2.4** Drive bring-up locally via `containers` `pkg/compose` (`Up` with build+wait) + `pkg/endpoint`/`pkg/health` gating; verify 52443/52080 listen on 0.0.0.0.
- **T2.5** Remote deploy path via `containers/cmd/deploy-stack` (flags/env contract).
- **T2.6** Paired mutation: break a health endpoint, assert health gate FAILS.
- Acceptance: `curl -k https://0.0.0.0:52443` returns the code-server login; podman ps shows healthy services.

# PHASE 3 — `vscode_profile_sync` (task roadmap)

- **T3.1** Extractor: read `~/.config/Code/User/{settings,keybindings}.json`, snippets, `code --list-extensions --show-versions`; emit a portable profile manifest (JSON). TDD with a fixture profile.
- **T3.2** Reproducer: install OpenVSX extensions via `code-server --install-extension` against the mirror; VSIX-sideload the 2 proprietary where obtainable (flag caveats); copy settings/keybindings/snippets into the image's User dir.
- **T3.3** Parity verifier (anti-bluff): after boot, assert installed-extension set ⊇ replicable set, settings applied, theme rendered (screenshot via HelixQA). Report non-replicable ones honestly.
- Acceptance: a real client sees the host's settings + 12 extensions + theme.

# PHASE 4 — QA (task roadmap)

- **T4.1** code-server challenge bank (`challenges`): health, auth gate, LSP responds, ws terminal echo, project-mount present, extension-presence, theme-applied, openvsx-mirror reachable. Anti-bluff evidence each.
- **T4.2** Drive existing `helix_qa/banks/helixcode-*.yaml` via `helixqa http --banks helix_qa/banks --base-url https://localhost:52443`.
- **T4.3** Autonomous web session `helixqa autonomous --platforms web` (crash detection, screenshots, tickets).
- **T4.4** Cover the 15 test types (unit/integration/e2e/full-automation/security/ddos/scaling/chaos/stress/performance/benchmarking/ui/ux/Challenges/autonomous-QA).
- **T4.5** Test orchestrator `tests/test_all.sh` + wire into `tests/pre_build_verification.sh`; each gate paired with a §1.1 mutation.
- Acceptance: all banks PASS with evidence; autonomous session GREEN; mutations prove gates.

# PHASE 5 — Docs + SQL + Docs-Chain (task roadmap)

- **T5.1** Docs: USER_GUIDE, ADMIN_MANUAL, ARCHITECTURE, SECURITY, PORTS, REPLICATION (md).
- **T5.2** Diagrams (Mermaid+PlantUML): topology, port-map, request/auth flow, projects-mount, replication, QA pipeline.
- **T5.3** SQL: `docs/sql/schema.sql` (projects, sessions, extensions, qa_results) + ERD; bidirectional md↔sqlite.
- **T5.4** Register a Docs-Chain chain (`docs_chain`) + `watch`/post-update hooks so md/html/pdf/docx/sqlite stay in sync (§11.4.12). Four-format export.
- Acceptance: `docs_chain verify` exit 0 across the corpus; hooks fire on change.

# PHASE 6 — Full validation (task roadmap)

- Real boot on host (podman compose up); real client opens `https://<host-ip>:52443`, authenticates, sees profile/theme, opens a `$PROJECTS` project, edits + uses terminal — captured as evidence. Autonomous HelixQA web session GREEN. Any defect → stop, root-cause, full rebuild + retest.

# PHASE 7 — Ship (task roadmap)

- Commit + push every owned submodule (new + reused that changed) to all their upstreams; commit + push main to all 4; create release tag `codeserver-1.0.0` (via `port`/`release_prefix` mechanism) across main + owned submodules; changelog; Docs-Chain final sync.

---

## Self-review (against spec)

- Spec §2 architecture → P2. §3 ports → port_prefix (P1) + P2 compose. §4 PROJECTS → P2 entrypoint. §5 replication → P3. §6 new submodules → P1. §7 QA → P4. §8 docs/SQL/DocsChain → P5. §9 perf → P2 (BuildKit/Caddy/inotify/tmux). §10 security → P2 Caddy/auth. §11 phases → P1-P7. §12 acceptance → P6. §13 constraints → Global Constraints. **All spec sections covered.**
- No placeholders in Phase 1 (executable now); P2-P7 are task roadmaps to be expanded into their own detailed plans when reached (per the writing-plans scope-check for multi-subsystem specs).
- Type consistency: `Exposed(prefix, internalPort, taken)` used consistently; `Mapping` struct defined once.
