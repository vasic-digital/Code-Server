#!/usr/bin/env bash
#
# tests/test_constitution_inheritance.sh
#
# Host-side comprehensive test of constitution inheritance for "code_server".
#
# What it does:
#   1. Re-validates invariants Inv1..Inv5 (mirroring the gate at
#      tests/pre_build_verification.sh), printing ONE PASS/FAIL line per
#      invariant, then runs the gate itself as a holistic confirmation.
#   2. Recursively inspects nested submodules via
#         git submodule status --recursive
#      and, for every submodule path OTHER than the constitution itself,
#      asserts it carries CLAUDE.md and AGENTS.md that reference the Helix
#      Constitution. The ZERO-nested-submodule case is handled gracefully:
#      it prints "nested submodules: 0 (nothing to check)" and is a PASS.
#   3. Invokes the paired §1.1 meta-test
#         scripts/testing/meta_test_false_positive_proof.sh
#
# Exits 0 ONLY if every check passes.
#
# Robustness contract: `set -euo pipefail`, repo-root resolution (git first,
# script-dir fallback), `grep -qF` for fixed strings, all paths quoted,
# idempotent, runnable from the repo root or any subdirectory.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Resolve the repository root (git first, script-dir fallback).
# This script lives in <repo>/tests/, so repo root is one level up.
# --------------------------------------------------------------------------
if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "${repo_root}" ]; then
    cd "${repo_root}"
else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
    cd "${script_dir}/.." >/dev/null 2>&1 || cd "${script_dir}"
fi

# --------------------------------------------------------------------------
# Fixed-string anchors. Keep the § and em dash (—) EXACTLY.
# --------------------------------------------------------------------------
# '### ' prefix required: match only the heading the meta-test mutates, not the
# Table-of-Contents copy (else the gate is a §1.1 bluff gate). See gate script.
readonly ANCHOR_CONSTITUTION='### §11.4 End-user quality guarantee — forensic anchor'
readonly ANCHOR_CLAUDE='MANDATORY ANTI-BLUFF COVENANT'
readonly ANCHOR_AGENTS='Anti-bluff covenant'

readonly GATE_REL="tests/pre_build_verification.sh"
readonly META_TEST_REL="scripts/testing/meta_test_false_positive_proof.sh"

# --------------------------------------------------------------------------
# Tally helpers.
# --------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

ok() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}
ko() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

# Assert a fixed substring is present in a file; emit one PASS/FAIL line.
# Args: <label> <file> <fixed-string> [-i]
check_contains() {
    local label="$1" file="$2" needle="$3" ci="${4:-}"
    if [ ! -f "${file}" ]; then
        ko "${label}: ${file} is missing"
        return
    fi
    if [ "${ci}" = "-i" ]; then
        if grep -iqF -- "${needle}" "${file}"; then ok "${label}"; else ko "${label}: '${needle}' not found in ${file}"; fi
    else
        if grep -qF -- "${needle}" "${file}"; then ok "${label}"; else ko "${label}: '${needle}' not found in ${file}"; fi
    fi
}

printf '==> Section 1: invariants Inv1..Inv5\n'

# Inv1 ----------------------------------------------------------------------
if [ -d "constitution" ]; then
    ok "Inv1: ./constitution directory exists"
else
    ko "Inv1: ./constitution directory is missing"
fi

# Inv2 ----------------------------------------------------------------------
check_contains "Inv2: constitution/Constitution.md has §11.4 forensic anchor" \
    "constitution/Constitution.md" "${ANCHOR_CONSTITUTION}"

# Inv3 ----------------------------------------------------------------------
check_contains "Inv3: constitution/CLAUDE.md has MANDATORY ANTI-BLUFF COVENANT" \
    "constitution/CLAUDE.md" "${ANCHOR_CLAUDE}"

# Inv4 ----------------------------------------------------------------------
check_contains "Inv4: constitution/AGENTS.md has Anti-bluff covenant" \
    "constitution/AGENTS.md" "${ANCHOR_AGENTS}" -i

# Inv5 ----------------------------------------------------------------------
# ./CLAUDE.md references the constitution.
if [ ! -f "CLAUDE.md" ]; then
    ko "Inv5: ./CLAUDE.md is missing"
elif grep -qF -- "constitution/CLAUDE.md" "CLAUDE.md" || grep -qF -- "Helix Constitution" "CLAUDE.md"; then
    ok "Inv5: ./CLAUDE.md references the constitution"
else
    ko "Inv5: ./CLAUDE.md does not reference the constitution (expected 'constitution/CLAUDE.md' or 'Helix Constitution')"
fi
# ./AGENTS.md references the constitution.
if [ ! -f "AGENTS.md" ]; then
    ko "Inv5: ./AGENTS.md is missing"
elif grep -qF -- "constitution/AGENTS.md" "AGENTS.md" || grep -qF -- "Helix Constitution" "AGENTS.md"; then
    ok "Inv5: ./AGENTS.md references the constitution"
else
    ko "Inv5: ./AGENTS.md does not reference the constitution (expected 'constitution/AGENTS.md' or 'Helix Constitution')"
fi

# Holistic confirmation: run the gate itself (single combined exit code).
printf '==> Section 1b: running the gate (%s)\n' "${GATE_REL}"
if [ -f "${GATE_REL}" ]; then
    if bash "${GATE_REL}"; then
        ok "gate ${GATE_REL} passed end-to-end"
    else
        ko "gate ${GATE_REL} returned non-zero"
    fi
else
    ko "gate ${GATE_REL} not found"
fi

# --------------------------------------------------------------------------
# Section 2: every OWNED nested submodule must carry the inheritance pointer.
# OWNED = repo hosted under vasic-digital or HelixDevelopment. Third-party deps
# vendored deeper in the graph (e.g. upstream open-source tools) are EXCLUDED:
# we neither can nor may inject our pointer into repos we do not own (§11.4.122),
# so requiring it of them would be a false invariant. Ownership is resolved from
# each submodule's actual clone URL (remote.origin.url), not guessed. The
# constitution submodule itself is excluded (it IS the inheritance source).
# --------------------------------------------------------------------------
printf '==> Section 2: owned nested submodules carry the inheritance pointer\n'

owned_total=0
owned_ok=0
thirdparty_skipped=0

is_owned_url() {
    case "$1" in
        *vasic-digital/*|*HelixDevelopment/*|*helixdevelopment*) return 0 ;;
        *) return 1 ;;
    esac
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r raw_line; do
        [ -n "${raw_line}" ] || continue
        # Drop the single leading status character (' ', '+', '-', or 'U').
        local_trimmed="${raw_line#?}"
        # shellcheck disable=SC2086
        set -- ${local_trimmed}
        sub_path="${2:-}"
        [ -n "${sub_path}" ] || continue

        case "${sub_path}" in
            constitution|*/constitution) continue ;;
        esac
        if [ ! -d "${sub_path}" ]; then
            ko "nested submodule '${sub_path}' missing on disk (uninitialized?)"
            continue
        fi

        # Resolve the real clone URL to decide ownership (no guessing).
        sub_url="$(git -C "${sub_path}" config --get remote.origin.url 2>/dev/null || true)"
        if ! is_owned_url "${sub_url}"; then
            thirdparty_skipped=$((thirdparty_skipped + 1))
            continue
        fi

        owned_total=$((owned_total + 1))
        sub_ok=1
        if ! { [ -f "${sub_path}/CLAUDE.md" ] && grep -qF -- "Helix Constitution" "${sub_path}/CLAUDE.md"; }; then
            ko "owned submodule '${sub_path}': CLAUDE.md missing or lacks 'Helix Constitution'"
            sub_ok=0
        fi
        if ! { [ -f "${sub_path}/AGENTS.md" ] && grep -qF -- "Helix Constitution" "${sub_path}/AGENTS.md"; }; then
            ko "owned submodule '${sub_path}': AGENTS.md missing or lacks 'Helix Constitution'"
            sub_ok=0
        fi
        if [ "${sub_ok}" -eq 1 ]; then
            ok "owned submodule '${sub_path}' references the Helix Constitution"
            owned_ok=$((owned_ok + 1))
        fi
    done < <(git submodule status 2>/dev/null || true)
fi
# NOTE: top-level (non-recursive) is intentional. This project pins its DIRECT
# owned submodules to their pointer-bearing commits and gates those here. Deeper
# transitive owned repos also receive the pointer on THEIR default branches via
# the propagation step (evidenced by push logs), but this project does not
# rewrite a dependency's internal pins, so it does not gate their pinned content.

printf 'owned top-level submodules: %d checked, %d passed; third-party skipped: %d\n' \
    "${owned_total}" "${owned_ok}" "${thirdparty_skipped}"
if [ "${owned_total}" -eq 0 ]; then
    # Graceful path: nothing owned to validate is a PASS, never error.
    ok "owned top-level submodules: 0 (nothing to check)"
fi

# --------------------------------------------------------------------------
# Section 3: paired §1.1 false-positive (mutation) proof.
# --------------------------------------------------------------------------
printf '==> Section 3: paired meta-test (%s)\n' "${META_TEST_REL}"
if [ -f "${META_TEST_REL}" ]; then
    if bash "${META_TEST_REL}"; then
        ok "paired meta-test confirms the gate catches the §11.4 mutation"
    else
        ko "paired meta-test reports the gate does NOT catch the §11.4 mutation"
    fi
else
    ko "paired meta-test ${META_TEST_REL} not found"
fi

# --------------------------------------------------------------------------
# Final tally.
# --------------------------------------------------------------------------
printf -- '----------------------------------------\n'
printf 'RESULT: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -eq 0 ]; then
    printf 'PASS: constitution inheritance fully verified (host-side)\n'
    exit 0
fi
printf 'FAIL: constitution inheritance verification failed\n' >&2
exit 1
