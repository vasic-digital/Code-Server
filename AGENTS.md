# Code Server — Agent Guide

> Base agent rules: `constitution/AGENTS.md` — READ IT FIRST.
> The base file is authoritative for any topic not covered here.
> Project-specific rules below extend them; they never weaken them.
>
> Canonical reference: Helix Constitution —
> https://github.com/HelixDevelopment/HelixConstitution
> Locate the constitution submodule from any nested depth via
> `constitution/find_constitution.sh`.

## Project-specific agent rules (Code Server)

- Release/tag prefix: `codeserver` (see `.env` `HELIX_RELEASE_PREFIX`;
  fallback = snake_case root dir name). Per constitution §11.4.151.
- Inheritance is gated by `tests/pre_build_verification.sh` and proven
  non-bluff by `scripts/testing/meta_test_false_positive_proof.sh`.
- Project-specific configuration (services, ports, hosts, credentials)
  lives in this repo and `.env` — NEVER in the constitution submodule.
