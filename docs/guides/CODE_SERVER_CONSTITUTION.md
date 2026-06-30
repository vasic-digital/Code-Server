# Code Server Constitution

This constitution **extends** the Helix Universal Constitution at
`../../constitution/Constitution.md`. All clauses there apply unless
explicitly overridden below with an explicit `Override §X.Y` section.

## Project identity

- Project name: **Code Server**
- Release / version prefix: `codeserver` (per Helix §11.4.151 — resolved
  from `HELIX_RELEASE_PREFIX` in `.env`, fallback = lowercased snake_case
  of the root project directory name). Example tag: `codeserver-1.0.0`.

## Inheritance

- `CLAUDE.md` and `AGENTS.md` at the repo root point to
  `constitution/CLAUDE.md` and `constitution/AGENTS.md`.
- The inheritance gate `tests/pre_build_verification.sh` enforces that the
  constitution submodule is present and intact (forensic §11.4 anchor,
  anti-bluff covenant anchors).
- The paired §1.1 mutation `scripts/testing/meta_test_false_positive_proof.sh`
  proves the gate catches a missing-inheritance regression.

## Project-specific clauses

(None yet — this project is at MVP stage. Add project-specific, EARNED
rules here. Universal rules belong upstream in the Helix Constitution, never
duplicated here.)

### Override sections

(None.)
