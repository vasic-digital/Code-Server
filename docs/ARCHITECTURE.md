# HelixCode — Architecture

**Revision:** 1 · **Last modified:** 2026-06-30

HelixCode is a decoupled, IDE-swappable, containerized browser-IDE platform built
by composing reusable Helix/vasic-digital submodules. See the design spec
(`docs/superpowers/specs/2026-06-30-helixcode-platform-design.md`) for the full
rationale.

## Stack topology

```mermaid
flowchart TD
  subgraph net["Network (0.0.0.0)"]
    C1["Browser client"]
  end
  C1 -- "https :52443 (TLS1.3, HTTP/3, brotli)" --> CADDY
  C1 -- "http :52080 (301 redirect)" --> CADDY
  subgraph compose["Podman/Docker compose network"]
    CADDY["Caddy (edge)\nTLS · reverse_proxy · rate-limit"]
    CS["code-server\nVSCode in browser · tmux shells"]
    OVX["openvsx mirror\n(coder/code-marketplace) — P2-remaining"]
    CADDY -- "proxy :8080" --> CS
    CS -- "EXTENSIONS_GALLERY" --> OVX
  end
  CS -- "bind-mounts (:Z, keep-id)" --> PROJ["$PROJECTS host paths\n/home/coder/projects/<name>"]
```

## Reuse map (submodules)

```mermaid
flowchart LR
  HC["code_server (HelixCode consumer)"]
  HC --> CW["code_workspace\n(orchestration engine)"]
  HC --> VPS["vscode_profile_sync\n(profile replication)"]
  HC --> PP["port_prefix\n(52000-52999 mapping)"]
  HC --> CON["constitution"]
  CW --> CONT["containers\n(runtime/compose/health)"]
  HC --> CH["challenges"]
  HC --> HQ["helix_qa\n(autonomous QA banks)"]
  HC --> DC["docs_chain\n(md<->sqlite<->html/pdf/docx)"]
```

## Request / auth flow

```mermaid
sequenceDiagram
  participant U as Browser
  participant E as Caddy :52443
  participant S as code-server :8080
  U->>E: GET / (TLS1.3)
  E->>S: proxy GET /
  S-->>E: 302 /login (if unauthenticated)
  E-->>U: 302 /login
  U->>E: POST /login (password)
  E->>S: proxy POST /login
  S-->>U: Set-Cookie + workspace (projects open)
```

## Port mapping (port_prefix band 52)

| Service | Internal | Exposed (0.0.0.0) |
|---|---|---|
| Caddy HTTPS | 443 | 52443 |
| Caddy HTTP→HTTPS | 80 | 52080 |
| code-server (debug, optional) | 8080 | 52808 |
| openvsx mirror (optional external) | 3000 | 52083 |

Rule: exposed = `prefix*1000 + (internal % 1000)`, linear-probed for collisions,
guaranteed ≤ 65535. Implemented by the `port_prefix` submodule.

## $PROJECTS mount flow

```mermaid
flowchart LR
  ENV["PROJECTS=/srv/api:/srv/web"] --> UP["deploy/up.sh"]
  UP --> GEN["generate compose.projects.yml\n(bind mounts :Z, keep-id)"]
  GEN --> COMPOSE["podman compose up"]
  COMPOSE --> M1["/home/coder/projects/api"]
  COMPOSE --> M2["/home/coder/projects/web"]
```

## Data model (SQL — planned P5)

A SQLite catalog (bidirectionally synced to Markdown via Docs Chain):

```mermaid
erDiagram
  PROJECTS ||--o{ SESSIONS : opens
  PROJECTS {
    int id PK
    string name
    string host_path
    string mount_path
  }
  SESSIONS {
    int id PK
    int project_id FK
    string client
    datetime started_at
  }
  EXTENSIONS {
    string id PK
    string source
    string parity_state
  }
  QA_RESULTS {
    int id PK
    string bank
    string verdict
    string evidence_path
  }
```

## Verification posture (anti-bluff)

Every PASS carries captured runtime evidence; every gate is paired with a §1.1
mutation; the platform's acceptance is an autonomous HelixQA web session that a
real client drives end-to-end (open → authenticate → see replicated profile →
edit a `$PROJECTS` file → use a terminal), with screenshots/HTTP evidence.
