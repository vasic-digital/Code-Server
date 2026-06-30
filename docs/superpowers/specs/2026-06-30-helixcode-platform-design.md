# HelixCode — Containerized Web-IDE Platform — Design Spec

| Field | Value |
|---|---|
| Date | 2026-06-30 |
| Status | APPROVED (design) — pending implementation plan |
| Authority | Operator mandate (2026-06-30) |
| Consumes | `constitution`, `containers`, `challenges`, `helix_qa`, `docs_chain` submodules |
| Produces | 3 new PUBLIC vasic-digital submodules + this consumer repo |

This constitution-governed design **extends** the Helix Universal Constitution
(`constitution/Constitution.md`); all clauses there apply. No project-specific
naming/keys leak into shared submodules; no secrets anywhere; every gate paired
with a §1.1 mutation; no `--force`/`--no-verify`/bypass; backups before
destructive ops.

---

## 1. Goal & non-goals

**Goal.** A fully containerized, network-exposed browser VSCode (code-server)
that any LAN user or dedicated-server client can open and **immediately start
working** in — exposing the host's `$PROJECTS` with permissive permissions, and
reproducing the host VSCode profile (settings, extensions, theme) as closely as
licensing allows. Maximal reuse of existing Helix/vasic-digital submodules;
maximal decoupling into new reusable submodules; fully tested (4-layer +
Challenges + HelixQA autonomous sessions); fully documented (guides, diagrams,
SQL) with Docs-Chain sync.

**Non-goals (YAGNI).** Multi-tenant RBAC/SSO quotas (Coder v2 territory —
documented upgrade path, not built now); Kubernetes (compose only); building a
new IDE (reuse `coder/code-server`).

## 2. Architecture (decoupled, IDE-swappable)

One Podman/Docker **compose** stack, orchestrated via the `containers` submodule
(`runtime.AutoDetect` Podman-first; `pkg/compose` local `up -d --build`;
`pkg/endpoint`+`pkg/health` gating; `cmd/deploy-stack` for remote server). The
`containers` module does **not** generate compose YAML — we author
`compose.codeserver.yml` and drive it with the module.

```
[clients on LAN / dedicated server — 0.0.0.0]
  │  https (HTTP/3 + brotli + websockets)
  ▼
Caddy (edge)  ── TLS: mkcert (LAN) | Let's Encrypt (public server)
  │            ── rate-limit; X-Forwarded-For; fail2ban-readable logs
  ▼  (compose network)
code-server (coder/code-server)
  │  auth: password (defense-in-depth) behind proxy; optional oauth2-proxy/OIDC later
  │  shells default into tmux (durable terminals across ws drops)
  │  EXTENSIONS_GALLERY → openvsx-mirror
  ├─ bind-mounts: $PROJECTS entries → /home/coder/projects/<name>  (:Z, --userns=keep-id, permissive)
  └─ baked profile: settings.json + extensions + theme (host parity)
  ▼
openvsx-mirror (coder/code-marketplace, AGPL single Go binary) — self-hosted gallery
```

Layers are independent units (own purpose, well-defined interface): edge proxy,
IDE, gallery, orchestration engine, profile-sync, port-mapper. Each testable in
isolation.

## 3. Port scheme — prefix `52` → range **52000–52999**

Rule: every **exposed host** port is `52` + a 3-digit suffix, so it always
starts with `52` and is always ≤ 65535 (max 52999). Internal services
communicate over the compose network and are NOT host-published. Canonical table
(authoritative; collisions resolved here):

| Service | Internal port | Exposed host port (0.0.0.0) |
|---|---|---|
| Caddy HTTPS — **main entry** | 443 | **52443** |
| Caddy HTTP → HTTPS redirect | 80 | **52080** |
| code-server (direct/debug; optional) | 8080 | **52808** |
| openvsx mirror (optional external) | 3000 | **52083** |

Implemented by the new **`port_prefix`** submodule (deterministic mapping,
overflow-safe, collision-detected, emits the table + the compose `ports:` lines).

## 4. `$PROJECTS` exposure & permissions

- `PROJECTS` (host env) = colon-separated absolute paths (PATH-style), e.g.
  `PROJECTS=/home/u/api:/home/u/web`.
- Entrypoint parses it and, per entry, adds a compose bind mount
  `${path}:/home/coder/projects/${basename}:Z` (rootless: `--userns=keep-id` so
  ownership matches the host user; SELinux `:Z`).
- Permissions permissive (operator mandate: immediate work). A generated
  multi-root `/home/coder/projects/helixcode.code-workspace` opens all projects
  at once. Empty/unset `PROJECTS` → friendly empty-workspace landing.

## 5. Host-VSCode replication (aggressive parity)

Source: host MS Code `~/.config/Code/User/` + `code --list-extensions`.
- **Settings/keybindings/snippets** copied verbatim into code-server User dir
  (host has 5 settings keys, no secrets; no keybindings/snippets → defaults).
- **Extensions (14): 12 installable from the Open VSX mirror**; **2 proprietary**
  (`github.copilot-chat`, `ms-vscode-remote.remote-containers`) attempted via
  VSIX sideload where obtainable, each flagged with its license/runtime caveat
  (copilot-chat needs the proprietary backend; remote-containers needs the
  closed VS Code Server code-server lacks) — honest report, never a bluff PASS.
- **Theme**: host uses built-in Default Dark Modern + Seti icons → bundled with
  code-server → **full visual parity** with zero marketplace dependency.
- Done by the new **`vscode_profile_sync`** submodule (extract → reproduce).

## 6. New PUBLIC reusable submodules (vasic-digital; created on plan start)

Repos created via `gh repo create` (GitHub) + `glab repo create` (GitLab),
**public**, snake_case, each: own constitution inheritance pointer, multi-upstream
`upstreams/`, 4-layer tests, README/ARCHITECTURE, decoupled (zero consumer names).

1. **`code_workspace`** — generic containerized browser-IDE orchestration engine:
   compose template renderer + entrypoint + `$PROJECTS` mounting + edge/proxy
   wiring; depends on `containers`. The reusable core; HelixCode consumes it.
2. **`vscode_profile_sync`** — desktop-VSCode/VSCodium profile extraction →
   code-server/openvscode-server reproduction (Open VSX install + VSIX sideload).
3. **`port_prefix`** — prefixed-port mapping library + CLI (deterministic,
   ≤65535, collision-resolved, compose-ports emitter).

This `code_server` repo (= HelixCode) is the **consumer** wiring all submodules
into the concrete platform.

## 7. QA strategy — reuse + extend (anti-bluff, all 15 test types)

`helix_qa/banks/helixcode-*.yaml` (20+ banks) already target this IDE. Plan:
- Drive existing banks: `helixqa http --banks helix_qa/banks --base-url https://localhost:52443`.
- Add a **code-server challenge bank** (`challenges`): project-mount present,
  extension-presence, theme applied, LSP responds, websocket terminal echoes,
  auth gate, Open VSX mirror reachable.
- Cover the **15 CONST-050(B) test types** (unit, integration, e2e,
  full-automation, security, ddos, scaling, chaos, stress, performance,
  benchmarking, ui, ux, Challenges, autonomous-QA-session) — load-bearing set for
  a web IDE called out in §7.1.
- **Autonomous HelixQA web sessions** (`helixqa autonomous --platforms web`):
  real-time crash detection, per-step screenshot validation, evidence
  collection, auto-tickets (`HQA-####.md`).
- **Anti-bluff**: `ValidateAntiBluff` enforced — every PASS carries positive
  runtime evidence (HTTP status/body/latency, ws payloads, screenshots).
- **§1.1 paired mutations** for every gate (reuse the three templates;
  deliberately-broken-target phase that MUST FAIL).

## 8. Documentation, diagrams, SQL, Docs-Chain

- Docs: `README`, `docs/USER_GUIDE`, `docs/ADMIN_MANUAL`, `docs/ARCHITECTURE`,
  `docs/SECURITY`, `docs/PORTS`, `docs/REPLICATION`.
- Diagrams (Mermaid + PlantUML): compose topology, port map, request/auth flow,
  PROJECTS-mount flow, profile-replication flow, QA pipeline.
- **SQL** (SQLite, schema + ERD): `projects` (registry from `$PROJECTS`),
  `sessions` (active IDE sessions), `extensions` (resolved parity state),
  `qa_results` (bank/challenge outcomes + evidence paths). Full DDL in
  `docs/sql/schema.sql`.
- **Docs Chain**: register a chain so md ↔ sqlite ↔ html/pdf/docx stay in sync;
  `watch` daemon + post-update hooks keep every artifact current (§11.4.12).

## 9. Performance/UX game-changers (incorporated)

BuildKit `--mount=type=cache` + warm prebuilt dev image (cold-open minutes→pull);
self-hosted Open VSX mirror (dodges MS ToS + namespace-squatting); Caddy
HTTP/3+brotli (~latency win on lossy nets); host `inotify`
(`fs.inotify.max_user_watches=524288`) + baked `files.watcherExclude`; **tmux**
durable terminals; health-gated lazy startup via `containers` `pkg/lifecycle`.

## 10. Security model (0.0.0.0 exposure)

Never expose code-server raw (it grants host shell). Edge: Caddy TLS + rate-limit
+ fail2ban (reads `X-Forwarded-For`, bans in `DOCKER-USER`/nft chain). Auth:
password by default (immediate use) with an optional `oauth2-proxy`/OIDC drop-in.
TLS: mkcert for LAN (LE can't issue for bare IPs), Let's Encrypt (DNS-01) for a
public server. Secrets only in git-ignored `.env` (§11.4.10); `.env.example`
tracked with placeholders.

## 11. Phases → tasks (detail expanded in the implementation plan)

- **P1 Bootstrap submodules.** Create the 3 public repos (gh+glab, multi-upstream),
  scaffold each (constitution pointer, tests, README), add as submodules at root.
- **P2 `code_workspace` engine + stack.** Compose renderer, entrypoint,
  `$PROJECTS` mount, Caddy + code-server + openvsx-mirror; BuildKit cache; bring
  up locally via `containers` `pkg/compose`; health-gate; expose 52xxx on 0.0.0.0.
- **P3 `vscode_profile_sync`.** Extract host profile; install 12 Open VSX + 2 VSIX;
  apply settings/theme; verify parity.
- **P4 QA.** code-server challenge bank; drive helixcode banks; autonomous web
  session; 15-type coverage; anti-bluff + paired mutations; test orchestrator +
  pre-build gate.
- **P5 Docs + SQL + Docs-Chain.** Guides, diagrams, SQL schema+ERD, register the
  chain + hooks.
- **P6 Full validation.** Real boot, real client, autonomous QA GREEN with
  captured evidence; fix at root cause + retest from scratch on any defect.
- **P7 Ship.** Commit + push every submodule and the main repo to all upstreams;
  project-prefixed release tag `codeserver-1.0.0`.

## 12. Testing matrix (acceptance)

Every component: unit + integration + e2e + the applicable subset of the 15
HelixQA types. Platform acceptance = autonomous HelixQA web session GREEN with
positive runtime evidence (real client opens an exposed 52xxx URL, authenticates,
sees the replicated profile/theme, opens a `$PROJECTS` project, edits + uses a
terminal) + all challenge banks PASS + every gate has a passing paired §1.1
mutation.

## 13. Constraints honored

No project-specific content in shared submodules · no secrets/PII anywhere ·
every gate paired with a mutation · no `--force`/`--no-verify`/bypass · hardlinked
`.git` backups before destructive ops · no test-cycle continuation past a
discovered defect (root-cause + full retest) · evidence-only PASS (anti-bluff) ·
submodule commits propagate first; tags mirrored; docs always in sync.
