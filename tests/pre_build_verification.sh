#!/usr/bin/env bash
#
# tests/pre_build_verification.sh
#
# Inheritance GATE for the "code_server" project.
#
# This script is the single source of truth that proves this repository
# correctly inherits from the Helix Constitution submodule mounted at
# ./constitution.  It is intended to run *before any build* and to be
# invoked by the constitution meta-test harness:
#
#     bash constitution/meta_test_inheritance.sh "bash tests/pre_build_verification.sh"
#
# It checks five invariants (Inv1..Inv5).  On the FIRST failure it prints
#     FAIL: <which invariant>
# to stderr and exits NON-ZERO.  On full success it prints
#     PASS: constitution inheritance verified
# and exits 0.
#
# Robustness contract:
#   * `set -euo pipefail`
#   * resolves the repo root (git first, script-dir fallback)
#   * uses `grep -qF` for fixed-string matching (no regex surprises)
#   * never assumes the constitution files are small
#   * quotes every path; safe to run from any working directory; idempotent
#
set -euo pipefail

# --------------------------------------------------------------------------
# Resolve the repository root so the gate works from any CWD.
# Prefer git; fall back to the script's own directory (.. = repo root).
# --------------------------------------------------------------------------
if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "${repo_root}" ]; then
    cd "${repo_root}"
else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
    # This script lives in <repo>/tests/, so the repo root is one level up.
    cd "${script_dir}/.." >/dev/null 2>&1 || cd "${script_dir}"
fi

# --------------------------------------------------------------------------
# Fixed-string anchors. Keep the section sign (§) and em dash (—) EXACTLY.
# ANCHOR_CONSTITUTION MUST keep the leading '### ' heading prefix: it makes the
# needle match ONLY the section heading (the exact line constitution/
# meta_test_inheritance.sh mutates out), NOT the identical Table-of-Contents
# entry ('- [§11.4 …]'). Without '### ' the gate stays green after the mutation
# (the TOC copy survives) — i.e. a §1.1 BLUFF GATE. Do not "simplify" this.
# --------------------------------------------------------------------------
readonly ANCHOR_CONSTITUTION='### §11.4 End-user quality guarantee — forensic anchor'
readonly ANCHOR_CLAUDE='MANDATORY ANTI-BLUFF COVENANT'
readonly ANCHOR_AGENTS='Anti-bluff covenant'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# --------------------------------------------------------------------------
# Inv1: ./constitution directory exists.
# --------------------------------------------------------------------------
[ -d "constitution" ] \
    || fail "Inv1: ./constitution directory is missing (submodule not mounted)"

# --------------------------------------------------------------------------
# Inv2: ./constitution/Constitution.md exists AND contains the §11.4
#       forensic-anchor substring.
# --------------------------------------------------------------------------
[ -f "constitution/Constitution.md" ] \
    || fail "Inv2: ./constitution/Constitution.md is missing"
grep -qF -- "${ANCHOR_CONSTITUTION}" "constitution/Constitution.md" \
    || fail "Inv2: ./constitution/Constitution.md is missing the §11.4 forensic-anchor line"

# --------------------------------------------------------------------------
# Inv3: ./constitution/CLAUDE.md exists AND contains the anti-bluff covenant.
# --------------------------------------------------------------------------
[ -f "constitution/CLAUDE.md" ] \
    || fail "Inv3: ./constitution/CLAUDE.md is missing"
grep -qF -- "${ANCHOR_CLAUDE}" "constitution/CLAUDE.md" \
    || fail "Inv3: ./constitution/CLAUDE.md is missing '${ANCHOR_CLAUDE}'"

# --------------------------------------------------------------------------
# Inv4: ./constitution/AGENTS.md exists AND contains the anti-bluff covenant
#       (case-insensitive).
# --------------------------------------------------------------------------
[ -f "constitution/AGENTS.md" ] \
    || fail "Inv4: ./constitution/AGENTS.md is missing"
grep -iqF -- "${ANCHOR_AGENTS}" "constitution/AGENTS.md" \
    || fail "Inv4: ./constitution/AGENTS.md is missing '${ANCHOR_AGENTS}' (case-insensitive)"

# --------------------------------------------------------------------------
# Inv5: ./CLAUDE.md and ./AGENTS.md each reference the constitution.
#       Preferred pointers (exact):
#           CLAUDE.md  -> "constitution/CLAUDE.md"
#           AGENTS.md  -> "constitution/AGENTS.md"
#       If those exact pointers are absent, accept "Helix Constitution".
#       Optionally validate a project-constitution file under docs/ if present,
#       but NEVER fail merely because such a docs/ file is absent.
# --------------------------------------------------------------------------
[ -f "CLAUDE.md" ] \
    || fail "Inv5: ./CLAUDE.md is missing (it must reference the constitution)"
if ! grep -qF -- "constitution/CLAUDE.md" "CLAUDE.md"; then
    grep -qF -- "Helix Constitution" "CLAUDE.md" \
        || fail "Inv5: ./CLAUDE.md does not reference the constitution (expected 'constitution/CLAUDE.md' or 'Helix Constitution')"
fi

[ -f "AGENTS.md" ] \
    || fail "Inv5: ./AGENTS.md is missing (it must reference the constitution)"
if ! grep -qF -- "constitution/AGENTS.md" "AGENTS.md"; then
    grep -qF -- "Helix Constitution" "AGENTS.md" \
        || fail "Inv5: ./AGENTS.md does not reference the constitution (expected 'constitution/AGENTS.md' or 'Helix Constitution')"
fi

# Optional: project-constitution doc(s) under docs/. Only validate if present.
if [ -d "docs" ]; then
    while IFS= read -r -d '' project_doc; do
        if ! grep -qF -- "Helix Constitution" "${project_doc}" \
            && ! grep -qF -- "constitution/" "${project_doc}"; then
            fail "Inv5: project-constitution doc '${project_doc}' exists but does not reference the Helix Constitution"
        fi
    done < <(find docs -type f -iname '*constitution*' -print0 2>/dev/null)
fi

printf 'PASS: constitution inheritance verified\n'
exit 0
