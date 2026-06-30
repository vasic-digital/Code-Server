# HelixCode — User & Operator Guide

**Revision:** 1 · **Last modified:** 2026-06-30

HelixCode is a containerized, network-exposed **VSCode in the browser**
(code-server) behind a Caddy edge. Open a URL, log in, and start coding in your
host projects immediately.

## 1. For end users (just code)

1. Open **`https://<server-ip>:52443`** in any browser on the network.
2. Accept the certificate warning (the LAN deployment uses a self-signed/internal
   TLS certificate).
3. Enter the password your operator gave you.
4. Your projects are already open under **Projects** (`/home/coder/projects/…`).
   Edit, run terminals (they persist across reconnects via tmux), use the
   integrated source control — exactly like desktop VSCode.

The editor ships with your team's settings, keybindings, and theme pre-applied.

## 2. For operators (deploy)

Prereqs: Podman (rootless) or Docker, on a host that can reach the projects.

```bash
cd deploy
cp .env.example .env
$EDITOR .env          # set CODE_SERVER_PASSWORD and PROJECTS
./up.sh               # builds + starts the stack
```

`.env` keys:

| Key | Meaning |
|---|---|
| `CODE_SERVER_PASSWORD` | Login password (kept only in git-ignored `.env`). |
| `PROJECTS` | Colon-separated absolute host paths to expose, e.g. `/srv/api:/srv/web`. Each appears at `/home/coder/projects/<name>`. |
| `PORT_PREFIX` | Exposed-port band prefix (default `52` → ports `52000-52999`). |

Exposed ports (all on `0.0.0.0`, reachable across the network):

| Service | URL |
|---|---|
| HTTPS (main entry) | `https://<host>:52443` |
| HTTP (redirects to HTTPS) | `http://<host>:52080` |

## 3. Operations

- **Status:** `cd deploy && podman compose -f compose.codeserver.yml -f compose.projects.yml ps`
- **Logs:** `podman logs deploy_code-server_1` · `podman logs deploy_caddy_1`
- **Stop:** `podman compose -f compose.codeserver.yml -f compose.projects.yml down`
- **Restart / re-read PROJECTS:** edit `.env`, then `./up.sh` again.

## 4. Security notes

- The IDE grants a host shell inside the container — never expose it without the
  Caddy edge + a strong `CODE_SERVER_PASSWORD`.
- LAN: self-signed/internal TLS (browser warning is expected). Public server:
  switch Caddy to Let's Encrypt (a domain is required — LE cannot issue for bare
  IPs).
- Secrets live only in the git-ignored `deploy/.env` (constitution §11.4.10).

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Browser cert warning | Expected on LAN (self-signed). Proceed / trust the cert. |
| `curl` fails TLS but browser works | curl built against GnuTLS mishandles Caddy's TLS1.3 internal cert. Use a browser, `openssl s_client`, or a curl built against OpenSSL. |
| A project is missing | Ensure its absolute path is in `PROJECTS` (colon-separated) and re-run `./up.sh`. |
| Port already in use | Another service holds a `52xxx` port; change `PORT_PREFIX` or free the port. |

## 6. Status of the platform

Phase 2 core (boot + TLS + reverse proxy + `$PROJECTS` mount + `0.0.0.0`
exposure) is implemented and verified. In progress per the implementation plan:
self-hosted Open VSX extension mirror, host-VSCode profile replication
(`vscode_profile_sync`), the autonomous QA banks (`helix_qa`), and the SQL +
Docs-Chain documentation sync. See `docs/superpowers/plans/`.
