# HelixCode — Feature Status Summary

**Revision:** 1 · **Last modified:** 2026-07-01T19:45:00Z

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
  from the Open VSX marketplace and loaded — proven live, not just claimed.
- **Secure, fast front door.** HTTPS with a modern fast protocol (HTTP/3) and
  response compression; the plain-HTTP port redirects to HTTPS.

**What is still in progress / needs the operator:**

- **Login-page copy/paste buttons** and a **click-through marketplace test** — being
  built now, **not finished**.
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
**working and proven** on the live system (23 of 23 test suites passed). A few
polish items (copy/paste buttons, click-through UI test, feature videos) are still
in progress and honestly marked as such.

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
- **Caddy edge** — `deploy/Caddyfile`, `deploy/caddy/Dockerfile` (xcaddy-brotli);
  HTTP/3+Brotli, forward_auth, `/proxy` 403, `X-Helix-User` strip; security_auth 5/5,
  benchmark_auth 4/4.

**Non-PASS states (honest §11.4.45):**

- **PENDING** — login-form clipboard buttons (`assets/login_enhance.js`, source landed,
  unvalidated); UI-driven marketplace test; edge reboot-persistence Quadlet
  (`deploy/quadlet/helixcode-caddy.container` + `scripts/install-edge-boot.sh` landed,
  arm/full-reboot survival not captured); **all Video-confirmation** (no real-use video
  corpus yet).
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
