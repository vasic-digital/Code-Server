# HelixCode deploy stack (Phase 2 — working core)

Containerized, network-exposed code-server behind a Caddy edge, with host
`$PROJECTS` bind-mounted. Verified working on Podman (rootless).

## Run

```bash
cp .env.example .env
# edit .env: set CODE_SERVER_PASSWORD and PROJECTS=/abs/proj1:/abs/proj2
./up.sh
```

Then open **https://<host-ip>:52443** (accept the self-signed cert) and log in.
HTTP on `:52080` redirects to HTTPS. Projects appear under
`/home/coder/projects/<name>`.

## Ports (port_prefix band 52, see ../port_prefix)

| Service | Internal | Exposed (0.0.0.0) |
|---|---|---|
| Caddy HTTPS (entry) | 443 | **52443** |
| Caddy HTTP → HTTPS | 80 | **52080** |

## Files

- `compose.codeserver.yml` — Caddy + code-server services (ports on 0.0.0.0).
- `Caddyfile` — internal TLS + reverse proxy + HTTP→HTTPS redirect (HTTP/3 ready).
- `up.sh` — engine: parses `$PROJECTS` → generates `compose.projects.yml` bind
  mounts (`:Z`), brings the stack up via `podman compose` (auto-detect).
- `.env.example` — config template (no secrets); copy to git-ignored `.env`.

## Verification (evidence)

- TLS1.3 handshake: `echo | openssl s_client -connect 127.0.0.1:52443 -servername localhost` → `Verify return code: 0 (ok)`.
- Login page served (2621 bytes, `<title>code-server login</title>`).
- `$PROJECTS` mounted (file readable inside the container).
- Note: a `curl` built against GnuTLS may fail the TLS1.3 handshake to Caddy's
  internal cert ("GnuTLS handshake Internal error") — a client quirk; use a
  browser, `openssl`, or a curl built against OpenSSL.

## Status

Phase 2 core (boot + TLS + proxy + projects-mount + 0.0.0.0) is implemented and
verified. Remaining P2: self-hosted Open VSX mirror service, BuildKit warm image,
generalize into the `code_workspace` renderer. See `docs/superpowers/plans/`.
