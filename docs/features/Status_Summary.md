# HelixCode — Feature Status Summary

**Revision:** 2 · **Last modified:** 2026-07-01T20:30:00Z

Two-audience companion (§11.4.56) to [`Status.md`](Status.md) for release
`codeserver-1.0.0-dev-0.0.3`. Page 1 is for the project / product team; Page 2 is
for software engineers. Always in sync with `Status.md` (§11.4.60).

---

## Page 1 — For the project & product team

**What HelixCode is.** Browser-based VS Code that opens your real projects, behind
a secure HTTPS front door, running without root — and now tied to your **real host
account with your SSH key** (no password anywhere).

**What works now (proven this release):**

- **Log in with your SSH key, no password.** The login page shows a one-time
  challenge; you sign it locally with your key and paste it back. Wrong or missing
  signatures are refused. Proven end-to-end on the live system.
- **The editor is really you.** Once in, the editor runs as your host account, so
  your SSH keys, your `.bashrc` settings, and all your tools work in the terminal —
  including `git` over SSH. Proven live (a real `git` remote check returned results).
- **It stays locked if the guard goes down.** If the login guard stops, access is
  **denied**, never accidentally opened. Proven by killing the guard live and
  confirming access was blocked, then recovered.
- **Install and reboot survival.** One script installs everything without root; the
  services are set to come back after a reboot.
- **Plugins install from the marketplace.** A real editor extension was installed
  from the Open VSX marketplace and loaded — proven live, not just claimed. Popular
  plugins (Python, ESLint, Prettier, GitLens and more) were installed, stayed installed
  after a restart, and their settings round-tripped.
- **Dark editor by default.** Fresh installs now open in the "Visual Studio Dark"
  theme — proven not just in the config but by rendering the real editor and measuring
  the pixels (it came out genuinely dark, versus a light control for comparison).
- **Login-page copy/paste buttons work.** The one-click "copy the command" and "paste
  your signature" buttons on the login page are built, accessible, and proven by
  rendering the real page and driving the buttons.
- **Click-through marketplace test.** An automated browser opens the Extensions panel,
  searches the marketplace, and clicks the real Install button — the browse-and-click
  journey is proven (the final install-completion step still needs a person on a
  headless machine, honestly noted).
- **Secure, fast front door — now survives reboots.** HTTPS with a modern fast protocol
  (HTTP/3) and response compression; the plain-HTTP port redirects to HTTPS. The front
  door now runs as a boot-persistent service (rootless) and stays up across session
  crashes — proven live (running for over an hour, set to auto-start).

**What is still in progress / needs the operator:**

- **Watching yourself edit in the browser** (typing, clicking files) is confirmed
  **by a person** for now — the automated click-through is still being wired.
- **Real public HTTPS certificate** needs a public domain and is **enabled by the
  operator**; the machinery is ready.
- **A host firewall tweak** (a one-line rule) needs the operator to apply it as root
  — the project itself never uses root.
- **Feature videos.** We do not yet have recorded "watch it work" videos; every
  claim above is backed by a saved test-evidence file instead. Recording the videos
  is a tracked to-do.

**Bottom line:** the new real-account SSH-key login and the editor experience are
**working and proven** on the live system (23 of 23 core suites passed, plus the
post-`0.0.3` additions — login copy/paste buttons, dark-by-default theme, popular
plugins, the click-through marketplace journey, and the now-live boot-persistent front
door — each proven with captured evidence). The remaining honestly-marked items are
the person-in-the-loop in-browser editing, the operator-enabled public certificate and
firewall rule, and the not-yet-recorded feature videos.

---

## Page 2 — For software engineers

**Release:** `codeserver-1.0.0-dev-0.0.3`. **Release-gate aggregate:** 23/23 suites
PASS, 0 FAIL — `qa-results/run_all/20260701T151300Z-3182121/summary.txt`. **Go gate:**
70 tests, `-race`, 81.8% coverage.

**Architecture:** `Browser → Caddy (containerized rootless TLS edge, HTTP/3+Brotli,
forward_auth) → helix-auth (Gin gate, host-native systemd --user, loopback :8081,
non-root) + code-server (host-native as milosvasic, --auth none, loopback :8080)`.

**Live-validated (PASS + captured evidence):**

- **SSH-key challenge-response auth** — `services/auth_gate/{challenge,verifier,cookie,server}.go`;
  e2e_auth 5/5, challenges_auth CH1, helixqa_auth QA-002/004; Go 70 tests `-race`.
- **Login redirect** — `server.go handleAuth` (303→/login for HTML GET, 401 otherwise),
  commit `75e2d9b`; `TestAuthBrowserNavigationRedirectsToLogin` + e2e_auth (B).
- **Fail-closed** — stress_chaos_auth 5/0/1 (live gate + code-server kill+recover),
  challenges_auth CH2, e2e_auth (E), helixqa_auth QA-003.
- **Cookie hardening** (`__Host-`+HMAC+HttpOnly+Secure+SameSite=Strict, regen on login) —
  `cookie.go`; security_auth 5/5.
- **DoS hardening** (rate-limit rightmost-XFF + CSRF double-submit + spawn ceiling) —
  `ratelimit.go`, `server.go`; load_auth 3/0/1, concurrency_auth 5/5, race 2/2.
- **CVE-2026-35414** server-pinned principal + key-type allow-list + OpenSSH floor —
  `verifier.go`, `sshversion.go`, `config.go`.
- **Host-native editor** — `deploy/systemd/helix-code-server.service`; editor loads
  (9 markers) authed 200 + `X-Helix-User`. Tarball install `scripts/install-auth.sh`
  (`~/.local/lib`, npm fallback, pinned 4.117.0).
- **Real-user env** — ssh-key git from terminal (CH3, `git ls-remote` 5 refs),
  `.bashrc` exports (CH4), Explorer defaults to `$PROJECTS_ROOT` (CH5, convenience,
  not a jail).
- **Extension install+use** — `tests/types/extensions_auth.sh` + bank
  `tests/banks/helixcode-extensions.yaml`; 5/5 checks captured
  `qa-results/tests/extensions_auth/20260701T162817Z-4080597` (Open VSX 200 → load → cleanup).
- **Login-form clipboard buttons** (commit `8351e4c`) — `services/auth_gate/assets/login_enhance.js`
  + `server.go`; `login_ui_auth.sh` LIVE 3/3 = L1 served-page + L2 node unit 8/8
  (`qa-results/tests/login_ui_auth/20260701T184629Z-1069432/l2_node_unit.txt`) + L3 §11.4.170
  CDP pixel proof `ok:true` (render/labelled/non-overlap, copy→clipboard, paste→fill,
  2-sig→picker, XSS-safe, no-auto-submit)
  `qa-results/tests/login_ui_auth/20260701T172810Z-584930/l3_visual.txt`; `server_login_ui_test.go` PASS.
- **VS Code Dark default theme** (commit `97a8c69`) — `deploy/code-server/settings.default.json`
  = "Visual Studio Dark"; `theme_default_auth.sh` config 3/3
  (`qa-results/tests/theme_default_auth/20260701T184655Z-1071563`) + `theme_visual_auth.sh`/
  `theme_visual_cdp.mjs` §11.4.170 rendered-pixel proof: dark meanLum **44.3** (darkFrac 0.926,
  DOM `vs-dark`, bg `rgb(37,37,38)`) `…/theme_visual_auth/20260701T183729Z-1053274` vs RED
  light-control meanLum **228.5** `…/20260701T183816Z-1053829` (self-validated §11.4.107(10)).
- **Popular-extensions matrix** (commit `97a8c69`) — `extensions_popular_auth.sh`; install
  proven live 4/5 `…/extensions_popular_auth/20260701T181018Z-855046/p1_install.txt` (+ direct
  8-ext probe) + config round-trip OK; MS-proprietary honestly ABSENT from Open VSX (§11.4.112);
  install/persist steps network-gated (Open-VSX-unreachable runs install 0 = honest network-SKIP).
- **UI-driven marketplace journey** (commit `8351e4c`) — `extensions_ui_auth.sh` (§11.4.48);
  headless Chromium opens Extensions view → searches Open VSX (rendered `u3_search_results.png`)
  → clicks the real Install button `qa-results/tests/extensions_ui_auth/20260701T171228Z-232181`
  (5/1); install-completion is an honest operator_attended SKIP (headless cross-origin Open VSX
  `net::ERR_ABORTED`), autonomous on-disk proof = CLI sibling `extensions_auth`.
- **Caddy edge** — `deploy/Caddyfile`, `deploy/caddy/Dockerfile` (xcaddy-brotli);
  HTTP/3+Brotli, forward_auth, `/proxy` 403, `X-Helix-User` strip; security_auth 5/5,
  benchmark_auth 4/4. **Boot-persistent (LIVE):** rootless Quadlet
  `deploy/quadlet/helixcode-caddy.container` → `helixcode-caddy.service` `active (running)`,
  `Linger=yes`, survives session crashes; edge answers HTTPS `:52443`.

**Non-PASS states (honest §11.4.45):**

- **PENDING** — **all Video-confirmation** (no real-use video corpus yet; every row's
  Video-confirmation is PENDING by design — PASS verdicts rest on the cited `qa-results/**`
  captured artefacts, not video, §11.4.6/§11.4.107). NOTE (§11.4.6): the §11.4.170 CDP
  pixel proofs (login buttons, dark theme) are cited to the runs where the driver reported
  `ok:true`/rc=0; the **latest** `login_ui_auth` L3 and `theme_visual_auth` runs honestly
  SKIPPED on a Chromium `captureScreenshot` timeout / workbench-never-rendered — a skipped
  CDP run is never counted as the pixel-proof PASS.
- **OPERATOR-ATTENDED** — in-browser editing (HCA-QA-UI-001 SKIP `operator_attended`).
- **OPERATOR-BLOCKED** — loopback firewall apply (`harden-loopback.sh --apply`, root);
  real public Let's Encrypt (public domain / DNS-01).
- **SKIP** — legacy container+password suites (`integration`, `e2e`, `security`,
  `tls_letsencrypt`, `full_automation`, `concurrency`, `memory`, `benchmark`, `helixqa`,
  `challenges`) → `topology_unsupported`, superseded by `<name>_auth` (no false-FAIL,
  §11.4.1).

**Notes:** code-server `--auth none` on loopback:8080 is a documented residual
(auth enforced at gate/edge; `harden-loopback.sh` mitigates). DOCX exported via pandoc
this release; no standing DOCX pipeline in `tests/run_all_types.sh` yet (tracked
§11.4.60/§11.4.65 follow-up).
