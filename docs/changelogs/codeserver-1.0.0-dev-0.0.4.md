# codeserver-1.0.0-dev-0.0.4

**Revision:** 1 · **Last modified:** 2026-07-01T00:00:00Z

Fourth dev pre-release of **HelixCode**. This round hardens the
**real-account SSH-key auth stack** shipped in `codeserver-1.0.0-dev-0.0.3`
into something an operator can actually reach and keep running, and it makes the
**editor's extension (plugin) marketplace** a first-class, anti-bluff-tested
capability. Three themes: (1) a **login reachability + usability fix** — an
unauthenticated browser now lands on the login form instead of a bodyless "This
page isn't working"; (2) **durability + host-safety hardening** — the whole
stack (gate + editor + TLS edge) now survives session and full-host restarts,
installs without the fragile npm path, and closes the `--auth none` loopback
residual; (3) **marketplace coverage** — install / use / persist / configure
real Open VSX extensions, proven LIVE, plus a VS Code Dark default theme.

Authoritative sources: user guide
[`docs/guides/AUTH.md`](../guides/AUTH.md), extensions guide
[`docs/guides/EXTENSIONS.md`](../guides/EXTENSIONS.md), edge-boot guide
[`docs/guides/EDGE_BOOT.md`](../guides/EDGE_BOOT.md), feature ledger
[`docs/features/Status.md`](../features/Status.md), prior release
[`codeserver-1.0.0-dev-0.0.3.md`](codeserver-1.0.0-dev-0.0.3.md).

## Fix — unauthenticated browsers reach the login form (`75e2d9b`)

- **Symptom.** Browsing the site root unauthenticated returned a **bodyless
  401** (`forward_auth` denied with no login redirect) → Chrome rendered
  **"This page isn't working"** and the user never reached the login form.
- **Fix.** The gate's `GET /auth` now returns **`303 → /login`** for browser
  navigations (`GET` + `Accept: text/html`), which Caddy's `forward_auth` copies
  to the client so the browser lands on the login page. XHR / fetch / asset / API
  requests (`Accept` **without** `text/html`) still receive a **bare 401**, so a
  programmatic caller is never served an HTML login page.
- **Root-caused via systematic-debugging (§11.4.102).** The log's transient 502s
  were separately proven to be **matrix-time chaos, not steady-state** (150
  parallel authed requests → 150× `200`, 0 failures).
- **Regression guards (§11.4.135).** `TestAuthBrowserNavigationRedirectsToLogin`
  + `TestAuthNonBrowserRequestsStay401` (Go, deterministic 3/3) + `e2e_auth (B)`
  hardened to assert **browser → 303 → /login AND api → 401** (live 5/5).

## Hardening — durability, install robustness, host-safety (`e0519bf`)

Post-`dev-0.0.3` hardening, subagent-driven, each landed with captured or
sandbox-proven evidence:

- **Reboot-persistent TLS edge (`deploy/quadlet/helixcode-caddy.container` +
  `scripts/install-edge-boot.sh` + `docs/guides/EDGE_BOOT.md`).** A rootless-podman
  **Quadlet** so the Caddy edge survives a **full host reboot** — closing a real
  recurring outage where the compose edge's port-forwarder died with the
  launching session. The host-native gate + editor already persist via `systemd
  --user` linger; the Quadlet completes the trio. Dry-run-validated; the work
  caught + fixed a Quadlet `EnvironmentFile` boot bug. It does **not** auto-start
  (that would clash on `52443` with the live compose edge — operator opt-in).
- **Standalone-tarball code-server install (`scripts/install-auth.sh`).** The
  install switched to the **standalone GitHub-release tarball as PRIMARY** (npm
  was fragile — registry lag / `ENOENT`), with npm as fallback; §11.4.6
  version-verified, idempotent, sandbox-proven (fetch + extract into a temp dir,
  the live install untouched).
- **UID-scoped loopback firewall (`scripts/harden-loopback.sh` +
  `docs/scripts/harden-loopback.md` + `AUTH.md §5.1`).** A UID-scoped loopback
  **OUTPUT** firewall (nft / iptables) closing the `--auth none` residual;
  `--check` / `--apply` / `--remove`, **refuses to guess the account, refuses to
  escalate**; shellcheck-clean; `--check` proven with no root.
- **§11.4.65 exports.** Synchronized `.html` + `.pdf` siblings for all release
  docs (real-text verified).

## Feature — extension marketplace: install, use, persist, configure

Across `43e37a5`, `849dc9a`, `8351e4c`, and the pending theme/popular-extensions
landing, HelixCode's editor **extension (plugin)** capability becomes a
first-class, LIVE-tested feature. The marketplace is **Open VSX** (code-server's
default); the Microsoft VS Code Marketplace is licence-restricted to Microsoft
products and is **not** used (stated as fact, no bypass — §11.4.6 / §11.4.112).

- **Anti-bluff install + use suite (`43e37a5`,
  `tests/types/extensions_auth.sh`, §11.4.169).** Proves the extension capability
  LIVE, all in throwaway `mktemp` dirs so the operator's live extensions-dir is
  **never mutated** (§11.4.14): **X1** marketplace reachable (Open VSX API `200` +
  real version, SKIP-with-reason if offline); **X2** install from marketplace
  (`--install-extension redhat.vscode-yaml` → exit 0, listed @version, valid
  on-disk `package.json`); **X3** usable + **LOADED** (a live throwaway
  code-server extension host actually loads it); **X4** cleanup (throwaway
  instance down, dirs trap-removed, LIVE extensions-dir fingerprint unchanged).
  **Live run PASS = 5/0.** Registered in `run_all_types.sh` risk-order (§11.4.132)
  + Challenge bank `tests/banks/helixcode-extensions.yaml`.
- **Operator extensions guide (`849dc9a`, `docs/guides/EXTENSIONS.md`,
  §11.4.99-sourced).** Honest guide to the extension system: default marketplace
  is Open VSX; MS Marketplace licence-restriction stated factually; install via
  UI + CLI (`--install-extension` / `--list-extensions` / `--uninstall-extension`)
  with the HelixCode `--extensions-dir` caveat; gallery config via
  `product.json` / `EXTENSIONS_GALLERY` (**the `--extensions-gallery` CLI flag
  does NOT exist in 4.117.0** — §11.4.6 verified); local `.vsix`; troubleshooting.
  Sources verified 2026-07-01. Plus `scripts/show-extension-gallery.sh` — a
  **read-only** probe printing the configured gallery (no mutation, never
  switches to MS Marketplace).
- **Login-form copy/paste clipboard buttons (`8351e4c`, §11.4.169/§11.4.170).**
  Accessible **copy** (sign-command + bare challenge) and **paste** (recognize
  armored SSH signature block(s); multi-match picker) icon buttons on the login
  form. Client module `assets/login_enhance.js` is a UMD recognizer
  (regex for `BEGIN/END SSH SIGNATURE`), clipboard capability-probed with
  graceful fallback, inserts as textarea `.value` ONLY (**XSS-safe**), never
  auto-submits, progressive-enhancement (the page works JS-off). Proven by
  `server_login_ui_test.go` (Go PASS), `tests/types/login_recognition.test.js`
  (node unit 8/8), and `tests/types/login_ui_auth.sh` — L1 live served-page + L2
  node unit + **L3 host-rendered Chromium/CDP pixel proof** (buttons
  render / labelled / non-overlapping + copy→clipboard + paste→fill + 2-sig→picker
  + XSS-safe + no-auto-submit) — **LIVE PASS = 3/3** (§11.4.170 device-independent
  rendered-pixel proof).
- **UI-driven marketplace journey (`8351e4c`,
  `tests/types/extensions_ui_auth.sh` + bank).** Headless Chromium opens the
  Extensions view → searches Open VSX → clicks the real **Install** button, with
  pixel + OCR evidence — the real user-journey path (§11.4.48). **GREEN 5/1** with
  an honest **`operator_attended` SKIP** on install-completion (headless
  cross-origin Open VSX install hangs; the on-disk + host-load proof is the CLI
  sibling `extensions_auth` X2/X3 — §11.4.52, no faked PASS).
- **VS Code Dark default theme + popular-extensions coverage (pending commit —
  conductor to land; `deploy/code-server/settings.default.json`,
  `tests/types/theme_default_auth.sh`, `tests/types/extensions_popular_auth.sh`,
  `tests/run_all_types.sh`).** The seeded default settings set
  `workbench.colorTheme` to **Visual Studio Dark** (§11.4.162), which
  `install-auth.sh` copies to a fresh install's `User/settings.json` so every
  HelixCode deployment defaults to a VS Code dark theme; `theme_default_auth.sh`
  is the §11.4.135 regression guard (**3/3**). `extensions_popular_auth.sh`
  proves a curated set of **major popular** Open VSX extensions (Python / ESLint /
  Prettier / GitLens class) genuinely **install (P1) + use/load (P2) + persist
  across a fresh process (P3) + configure round-trip (P4)**, with the
  MS-proprietary set (Pylance / Live Share / Remote) confirmed **honestly ABSENT**
  from Open VSX (P5, licensing — §11.4.112), and the live extensions-dir left
  unmutated (P6).

## Feature ledger reconciliation (`eee6169`, §11.4.153)

`docs/features/Status.md` + a new `Status_Summary.md` (§11.4.56) + HTML / PDF /
DOCX exports (§11.4.153/§11.4.65), every row reconciled to a real file / evidence
(§11.4.6/§11.4.123): auth surface **PASS** (23/23 matrix, Go 70 tests `-race`);
login-redirect (`75e2d9b`) **PASS**; extension install+use **PASS**
(`extensions_auth` 5/5); reboot-persistence **PENDING** (landed; full-reboot
survival not yet captured); loopback firewall **OPERATOR-BLOCKED** (`--apply`
needs root). **Video-confirmation is honestly PENDING on every row** — no
real-use video corpus exists yet (NOT fabricated; PASS verdicts are backed by
cited `qa-results/**` artefacts). Legacy container+password suites report an
honest **SKIP**.

## Durability

The whole stack is now `systemd --user`-managed and reboot-persistent:

```
Browser ──HTTPS──▶ Caddy TLS edge  — rootless Podman compose (live) + Quadlet (reboot-boot, opt-in)
                    ├─ forward_auth ─▶ helix-auth   (host-native, systemd --user, loopback:8081)
                    └─ reverse_proxy ─▶ code-server (host-native AS milosvasic, systemd --user,
                                          --auth none, loopback:8080, seeded VS Code Dark default)
```

- **Gate + editor** persist across logout via `systemd --user` **linger**.
- **TLS edge** persists across a **full host reboot** via the rootless-podman
  **Quadlet** (`scripts/install-edge-boot.sh`, opt-in so it does not clash with
  the live compose edge on `52443`).
- **Loopback `--auth none` residual** closable by the UID-scoped firewall
  (`scripts/harden-loopback.sh`, root-gated `--apply`).

## Honest boundaries (§11.4.6)

- **Marketplace = Open VSX, not the MS VS Code Marketplace.** The Microsoft
  Marketplace is **licence-restricted to Microsoft products** — **Pylance / Live
  Share / Remote-\* are unavailable** and confirmed ABSENT from Open VSX
  (documented, not a defect — §11.4.112). This is stated as fact; there is no
  bypass.
- **Public Let's Encrypt is operator-gated.** Publicly-trusted TLS needs a public
  domain + reachable `:80`/`:443` or a DNS-01 token (LAN box); the ACME machinery
  is proven against a local CA (`docs/guides/TLS.md`).
- **`--auth none` on loopback:8080 residual** is **mitigated, not eliminated in
  the default deployment.** The gate/edge enforce all auth; a local host process
  reaching `127.0.0.1:8080` bypasses it. The **root-gated**
  `scripts/harden-loopback.sh --apply` closes it (a UID-scoped OUTPUT firewall);
  it stays **OPERATOR-BLOCKED** in the ledger until an operator runs it with root.
- **Reboot-persistent edge is opt-in.** The Quadlet does **not** auto-start (it
  would clash on `52443` with the live compose edge); full-host-reboot survival
  is **PENDING** in the ledger until captured on a real reboot.
- **UI-driven marketplace install-completion is `operator_attended`.** Headless
  cross-origin Open VSX install hangs; the autonomous proof of install+load is the
  CLI path (`extensions_auth` X2/X3) — no faked GUI PASS (§11.4.52).
- **No real-use video corpus yet.** §11.4.153 video-confirmation is honestly
  PENDING on every ledger row; PASS verdicts rest on cited `qa-results/**`
  captured evidence, never a fabricated video.
- **code-server pinned to 4.117.0** (newest on npm at release time; install now
  prefers the standalone tarball).

## Testing (§11.4.169)

- **New / hardened suites** (`tests/types/`): `extensions_auth`,
  `extensions_ui_auth`, `login_ui_auth`, `login_recognition.test.js`,
  `theme_default_auth`, `extensions_popular_auth` — plus the hardened
  `e2e_auth (B)` browser-redirect regression assertion and the Go guards
  `TestAuthBrowserNavigationRedirectsToLogin` / `TestAuthNonBrowserRequestsStay401`.
- **Marketplace evidence path is anti-bluff (§11.4.69/§11.4.107):** every PASS
  cites captured evidence — real install output, real on-disk manifests + entry
  files, real fresh-process listings, a real config round-trip, a real
  host-rendered pixel proof — never a metadata-only pass; all in throwaway dirs
  so the live extensions-dir is provably unmutated (§11.4.14 / §11.4.122).
- All new suites registered in `run_all_types.sh` risk-order (§11.4.132) with
  their Challenge banks.

**LIVE VALIDATION AGGREGATE (release-gate run):** <conductor fills post-run>

## Migration

- **No breaking parameter changes from `dev-0.0.3`.** The SSH-key auth model,
  `HELIX_AUTH_*` parameters, and `PROJECTS_ROOT` are unchanged.
- **Reboot-persistent edge (optional):** `scripts/install-edge-boot.sh` installs
  the rootless-podman Quadlet (opt-in; stop the live compose edge first to avoid a
  `52443` clash).
- **Loopback hardening (optional, root):** `scripts/harden-loopback.sh --apply`
  closes the `--auth none` residual for the account.
- **Extensions:** install from Open VSX via the Extensions view or
  `code-server --install-extension <id>`; see `docs/guides/EXTENSIONS.md`.
- **Default theme:** fresh installs seed **Visual Studio Dark**; existing
  deployments keep their `User/settings.json`.
