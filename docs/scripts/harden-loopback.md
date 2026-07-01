# `harden-loopback.sh`

**Revision:** 1 · **Last modified:** 2026-07-01 · **Last verified:** 2026-07-01

Companion documentation (constitution §11.4.18) for `scripts/harden-loopback.sh`.
Run it from the repo root.

## Overview

Closes the documented **`--auth none` residual risk** of the host-native
real-account editor. The host-native code-server listens on `127.0.0.1:8080` with
`--auth none` — authentication is enforced **upstream** by the Caddy `forward_auth`
gate (`helix-auth`), **not** on the loopback socket itself. So on the raw loopback
socket there is **no per-UID access control**: any local process or user in the
host network namespace can connect to `127.0.0.1:8080` and get an interactive shell
**as the account**, completely bypassing the Caddy gate. This is stated honestly in
the `RESIDUAL RISK` block of
[`deploy/systemd/helix-code-server.service`](../../deploy/systemd/helix-code-server.service)
(FINDINGS Angle 2/D).

`harden-loopback.sh` installs the host-side mitigation named there: a **UID-scoped
loopback OUTPUT firewall rule** that DROPs connections to `127.0.0.1:<port>` made by
any UID **other than the account**. Only the account reaches code-server; rootless
Caddy connects **as the account** (via `host.containers.internal` → host loopback),
so the gate path stays allowed. Rootless-Podman pods sit in their own network
namespace and never reach host loopback unless host-networked.

This is **defence-in-depth** — a complement to the fail-closed Caddy gate, not a
replacement. It adds one narrow OUTPUT DROP rule (in a dedicated nft table, or a
single iptables OUTPUT rule) and touches nothing else, keeping §11.4.133 host
safety.

The **strongest** fix — a unix socket bind-mounted into the rootless Caddy
container — was assessed and **deferred** as fragile on the two-lifecycle topology
(see the note in
[`deploy/compose.codeserver.yml`](../../deploy/compose.codeserver.yml)); this
firewall rule is the recommended mitigation until then.

## Prerequisites

- **`--check`**: none beyond `bash` — read-only, **no root**. Reports state and the
  exact rule (dry-run). Note: reading the live ruleset (to confirm an *existing*
  rule) needs root; without it, `--check` honestly reports `UNKNOWN` and exits
  non-zero rather than claiming protection it could not verify.
- **`--apply` / `--remove`**: **root** + one of `nft` (preferred) or `iptables`.
  The script never escalates privileges itself — it refuses politely with the exact
  root re-run instruction when not run as root.

## Usage

```bash
scripts/harden-loopback.sh --check    # read-only state + dry-run rule (no root)
scripts/harden-loopback.sh --apply    # add the rule (root; idempotent)
scripts/harden-loopback.sh --remove   # delete the rule (root; idempotent)
scripts/harden-loopback.sh --help     # in-source doc header
```

Because the mitigation needs root, the operator applies it via their own root path:

```bash
# from the repo root, as the operator:
su - -c 'HELIX_AUTH_ACCOUNT=milosvasic /abs/path/to/scripts/harden-loopback.sh --apply'
# or sudo / doas / a root login shell — whatever your site uses.
```

## Configuration (never hard-coded — §11.4.6 / §11.4.28)

Precedence: **process env > `deploy/.env` > derived-from-unit > documented default.**

| Value | Source |
|---|---|
| Account (the only allowed UID) | `HELIX_AUTH_ACCOUNT` (process env wins, else `deploy/.env`). **Required** — the script refuses to guess a security-relevant identity and errors out if unset. It does **not** fall back to `id -un`, because under `--apply` as root that would be `root` and would build a wrong rule that locks the real account out. |
| Port | `HELIX_CS_PORT` (process env, else `deploy/.env`); else parsed from the real `--bind-addr 127.0.0.1:<port>` line of `deploy/systemd/helix-code-server.service`; else the documented default `8080`. |

The UID is resolved from the account via `id -u` (unambiguous across nft/iptables);
a non-existent account is a hard error.

## The rule it installs

**nftables (preferred)** — a dedicated table so removal is a clean, self-contained
delete that cannot disturb any other firewalling:

```
nft add table inet helixcode_loopback
nft add chain inet helixcode_loopback output { type filter hook output priority 0 ; policy accept ; }
nft add rule  inet helixcode_loopback output oifname "lo" tcp dport 8080 meta skuid != <UID> drop
```

**iptables (fallback)** — one OUTPUT rule using the `owner` match (this is the exact
form documented in the systemd unit's RESIDUAL RISK block):

```
iptables -A OUTPUT -o lo -p tcp --dport 8080 -m owner ! --uid-owner <UID> -j DROP
```

`--remove` deletes exactly this (nft: `nft delete table inet helixcode_loopback`;
iptables: the same rule with `-D`).

## Edge cases / internal behaviour

- **Idempotent.** `--apply` adds the rule only if absent; `--remove` deletes only if
  present. Re-running either is safe.
- **Exit codes.** `--check`: `0` = rule confirmed present (PROTECTED); `1` = rule
  absent **or** state could not be confirmed (fail-closed reporting — it never
  claims protection it did not verify). `--apply` / `--remove`: `0` on success or
  already-in-desired-state; non-zero on refusal (no root / no backend) or failure.
  No mode / unknown option: `2`.
- **No backend present.** `--check` reports `CANNOT VERIFY — treating as
  UNPROTECTED`, still prints the dry-run rule, exits `1`. `--apply` / `--remove`
  error out asking you to install nftables or iptables.
- **Runtime state, not persistent.** nft/iptables rules live in kernel runtime
  state and do **not** survive a reboot on their own. After `--apply`, persist them
  via your distro's ruleset-save mechanism (e.g. `nft list ruleset >
  /etc/nftables.conf` + the `nftables` service, or `iptables-save`) or a boot unit.
  `--apply` prints this reminder.
- **Never binds `0.0.0.0`, never escalates, never touches other units.** The script
  only ever adds/removes its own single loopback rule.

## Related

- `deploy/systemd/helix-code-server.service` — the RESIDUAL RISK block this script
  mitigates.
- `deploy/compose.codeserver.yml` — the deferred unix-socket alternative.
- [`docs/guides/AUTH.md`](../guides/AUTH.md) §5.1 — the operator-facing security note.
- `scripts/install-auth.sh` — installs the host-native editor + gate (this script is
  the optional loopback-hardening add-on, run separately with root).
