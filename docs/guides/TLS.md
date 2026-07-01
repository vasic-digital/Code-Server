# HelixCode — TLS / HTTPS Guide (self-signed, Let's Encrypt, internal ACME)

**Revision:** 1 · **Last modified:** 2026-07-01T00:00:00Z

How HelixCode terminates HTTPS at the Caddy edge, how to switch on **real
Let's Encrypt** with **automatic renewal + rotation**, and how the ACME flow is
**proven end-to-end** on a LAN box that has no public domain.

All TLS behavior is selected by `deploy/.env` knobs and rendered into the
`deploy/Caddyfile` by `deploy/up.sh`. No code changes are needed to switch modes
— edit `.env`, re-run `./up.sh`.

---

## 1. TLS modes (`TLS_MODE` in `deploy/.env`)

| `TLS_MODE` | Cert source | When to use | Operator must provide |
|---|---|---|---|
| `self-signed` *(default)* | per-boot self-signed cert served for all SNI | LAN box, no public domain (192.168.x.x) | nothing — accept the browser warning |
| `letsencrypt` | **real public Let's Encrypt** (trusted) | public domain reachable from the internet | `CS_DOMAIN`, `ACME_EMAIL`, open `:80`/`:443` **or** DNS-01 |
| `letsencrypt-staging` | LE **staging** (untrusted, high rate limits) | dry-run the ACME flow before going live | `CS_DOMAIN`, `ACME_EMAIL` |
| `internal-acme` | any ACME directory URL (Pebble / step-ca / smallstep) | private/enterprise CA, or the local proof harness | `CS_DOMAIN`, `ACME_EMAIL`, `ACME_CA_URL` |

The knobs (`.env.example` documents each; **never** put a real secret in
`.env.example` — §11.4.10):

```ini
TLS_MODE=self-signed
CS_DOMAIN=                 # FQDN Caddy issues/serves the cert for (ACME modes)
ACME_EMAIL=               # ACME account contact (ACME modes)
ACME_CA_URL=              # override ACME directory URL (required for internal-acme)
ACME_DNS_PROVIDER=        # optional DNS-01 provider (needs a custom Caddy build)
ACME_DNS_API_TOKEN=       # SECRET — lives ONLY in .env, never in the Caddyfile
```

`self-signed` is byte-for-byte the original HelixCode behavior — switching modes
away and back is safe and regenerates the exact same LAN config.

---

## 2. Turn on REAL Let's Encrypt (what YOU must provide)

Real public issuance is **operator-gated** — the ACME CA must prove you control
the domain. Pick ONE challenge path:

### 2a. HTTP-01 / TLS-ALPN-01 (simplest)

1. A **public domain** (e.g. `code.example.com`) whose DNS A/AAAA record points
   at this host's public IP.
2. Inbound **:80 and :443 reachable from the internet** to Caddy. HelixCode maps
   the edge to host ports `52080`/`52443`; for public LE you must forward public
   `80 -> 52080` and `443 -> 52443` (router/NAT/firewall), or run the edge on
   `80`/`443` directly. The CA connects to the domain on the standard ports.
3. In `deploy/.env`:
   ```ini
   TLS_MODE=letsencrypt
   CS_DOMAIN=code.example.com
   ACME_EMAIL=admin@example.com
   ```
4. `./up.sh`. Caddy obtains the cert on first boot and serves trusted HTTPS.

### 2b. DNS-01 (wildcard, or when :80/:443 aren't publicly reachable)

DNS-01 proves control by writing a TXT record — no inbound ports needed.

1. `ACME_DNS_PROVIDER=<caddy-dns-module>` (e.g. `cloudflare`, `route53`) and
   `ACME_DNS_API_TOKEN=<token>` in `.env` (**secret** — stays in the git-ignored
   `.env`; `up.sh` writes only `{env.ACME_DNS_API_TOKEN}` into the Caddyfile, and
   `compose.codeserver.yml` passes the token to the container via env — the token
   is **never** written to a tracked file, §11.4.10).
2. **A Caddy image built WITH that DNS provider plugin** — the stock
   `docker.io/library/caddy:2` image ships **no** DNS modules. Build one with
   [`xcaddy`](https://github.com/caddyserver/xcaddy) (e.g.
   `xcaddy build --with github.com/caddy-dns/cloudflare`) and set that image in
   `compose.codeserver.yml`.
3. `./up.sh`.

### 2c. Staging first

Set `TLS_MODE=letsencrypt-staging` to exercise the full flow against LE staging
(certs are **untrusted** but the rate limits are generous) before switching to
`letsencrypt`.

---

## 3. Automatic renewal + rotation

Caddy 2 does ACME natively: it **auto-renews each managed certificate ~30 days
before expiry** and hot-swaps the new leaf with **no downtime and no operator
action**. HelixCode does not re-implement this — it configures it and proves it.

**Renewal state persistence.** The ACME account key and every issued
certificate live in Caddy's `/data`, which `deploy/compose.codeserver.yml`
persists to the named volume `caddy-data`:

```yaml
volumes:
  - caddy-data:/data     # ACME account + certs — survives restart/reboot
```

Because `/data` is a persistent volume, a container restart or host reboot does
**not** re-issue from scratch (which would burn CA rate limits) — Caddy reloads
the existing account + certs and continues the renewal schedule. Rotation (a new
leaf replacing the old) is likewise handled automatically and served live.

---

## 4. Proof — how we know issuance + rotation actually work (anti-bluff)

A LAN box has no public domain, so we cannot burn real Let's Encrypt to prove the
mechanism. Instead the proof runs the **full ACME protocol against a local CA
(Pebble)** — deterministic, re-runnable, and completely isolated from the
installed stack.

- **Harness:** `deploy/acme/` — a self-contained rootless-podman compose project
  named **`hc_acme_proof`** on host port band **53xxx** (distinct from the
  installed `deploy` stack's 52xxx, so the two never collide — §11.4.119).
  Topology: `edge` (Caddy, `TLS_MODE=internal-acme`) → **obtains a cert via ACME
  from** `pebble` (local CA) → `reverse_proxy` → `backend` (trivial responder).
- **Run it:** `deploy/acme/run.sh` (or via the test suite). It:
  1. generates a mini-CA + a Pebble server cert (so Caddy trusts Pebble's ACME
     endpoint via `acme_ca_root`),
  2. brings the project up rootless,
  3. confirms the **served leaf's issuer is Pebble** (`openssl s_client` — the
     chain is `Pebble Root CA → Pebble Intermediate CA → leaf`),
  4. confirms the backend is served over that ACME leaf,
  5. **forces a rotation** (drops the stored cert + restarts the edge → Caddy
     re-obtains) and confirms a **new cert with a different serial** is served,
  6. tears the ephemeral project down in a `trap EXIT` (§11.4.14).
- **Test:** `tests/types/tls_letsencrypt.sh` — Layer A (static/regression) asserts
  `up.sh` is `TLS_MODE`-aware, the self-signed render is byte-identical, the knobs
  are documented, `caddy-data` persists renewal state, and the DNS-01 secret is
  never baked in; Layer B drives the Pebble harness and asserts issuer + serial
  rotation. Every PASS cites a captured evidence file under
  `qa-results/tests/tls_letsencrypt/<run-id>/`.

Captured example (a real run):

```
issuer : CN=Pebble Intermediate CA 025cc9
initial serial : 53C2368F3EA415B5
rotated serial : 4E5C2C704F8DE31A
ROTATION: CONFIRMED (serial changed)
```

If the Pebble/Caddy images can't be pulled (no network), Layer B is an **honest
SKIP** (`network_unreachable_external`) — never a faked PASS (§11.4.69).

---

## 5. Honest boundary (§11.4.6 / §11.4.112)

- The local-CA proof exercises the **real ACME issuance + renewal + rotation
  code path**; the *only* thing stubbed is domain-reachability validation
  (`PEBBLE_VA_ALWAYS_VALID`), because there is no public domain to validate. That
  validation step is exactly what **real public Let's Encrypt is gated on** — see
  §2 for what the operator must supply.
- Therefore: **real, publicly-trusted Let's Encrypt issuance is operator-gated**
  and cannot be autonomously proven on this LAN box. Provide a public domain +
  reachable ports (or a DNS-01 token) and switch `TLS_MODE=letsencrypt` to get a
  browser-trusted cert with the same automatic renewal.

## Sources verified

- Caddy Automatic HTTPS (ACME issuance + auto-renewal ~30 days pre-expiry):
  https://caddyserver.com/docs/automatic-https — verified 2026-07-01.
- Caddyfile global options `acme_ca`, `acme_ca_root`, `email`; `tls` DNS
  challenge: https://caddyserver.com/docs/caddyfile/options — verified 2026-07-01.
- Let's Encrypt Pebble (small ACME test server) + `PEBBLE_VA_ALWAYS_VALID`:
  https://github.com/letsencrypt/pebble — verified 2026-07-01.
- Let's Encrypt staging environment + challenge types:
  https://letsencrypt.org/docs/staging-environment/ ,
  https://letsencrypt.org/docs/challenge-types/ — verified 2026-07-01.
