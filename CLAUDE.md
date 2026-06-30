# Code Server

## INHERITED FROM constitution/CLAUDE.md

All rules in `constitution/CLAUDE.md` (and the
`constitution/Constitution.md` it references) apply unconditionally.
Project-specific rules below extend them — they do NOT weaken any
universal clause. When this file disagrees with the constitution
submodule, the constitution wins.

@constitution/CLAUDE.md

## Project-specific rules (Code Server)

<!-- Project-specific rules EXTEND, never weaken, the universal constitution.
     Hardware SKUs, service names, ports, table names, fix numbers, phase
     dates, vendor names — all belong HERE, never in the constitution. -->

- Release tags and version names use the project-derived prefix `codeserver`
  (resolved from `HELIX_RELEASE_PREFIX` in `.env`, else the lowercased
  snake_case root directory name) per constitution §11.4.151 / §11.4.29.
  Example: `codeserver-1.0.0`.
- Constitution inheritance is enforced by `tests/pre_build_verification.sh`
  (the inheritance gate) and proven non-bluff by
  `scripts/testing/meta_test_false_positive_proof.sh` (paired §1.1 mutation).
