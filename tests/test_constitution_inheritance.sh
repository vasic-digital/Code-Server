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
# Section 2: recursively verify nested submodules (excluding the constitution).
# --------------------------------------------------------------------------
printf '==> Section 2: nested submodules\n'

nested_total=0
nested_checked=0

# Collect submodule paths safely. `git submodule status --recursive` prints
# one line per submodule:  "[ +-U]<sha> <path> [(describe)]". We strip the
# leading status flag, then read the SHA and path. Process substitution keeps
# the counters in THIS shell (no subshell pipe).
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r raw_line; do
        [ -n "${raw_line}" ] || continue
        # Drop the single leading status character (' ', '+', '-', or 'U').
        local_trimmed="${raw_line#?}"
        # Fields: <sha> <path> [<describe...>]
        # shellcheck disable=SC2086
        set -- ${local_trimmed}
        sub_sha="${1:-}"
        sub_path="${2:-}"
        [ -n "${sub_path}" ] || continue

        # Skip the constitution submodule itself.
        case "${sub_path}" in
            constitution|*/constitution) continue ;;
        esac

        nested_total=$((nested_total + 1))

        if [ ! -d "${sub_path}" ]; then
            ko "nested submodule '${sub_path}' path does not exist on disk (uninitialized?)"
            continue
        fi

        sub_ok=1
        if [ -f "${sub_path}/CLAUDE.md" ] && grep -qF -- "Helix Constitution" "${sub_path}/CLAUDE.md"; then
            :
        else
            ko "nested submodule '${sub_path}': CLAUDE.md missing or does not reference 'Helix Constitution'"
            sub_ok=0
        fi
        if [ -f "${sub_path}/AGENTS.md" ] && grep -qF -- "Helix Constitution" "${sub_path}/AGENTS.md"; then
            :
        else
            ko "nested submodule '${sub_path}': AGENTS.md missing or does not reference 'Helix Constitution'"
            sub_ok=0
        fi
        if [ "${sub_ok}" -eq 1 ]; then
            ok "nested submodule '${sub_path}' references the Helix Constitution"
            nested_checked=$((nested_checked + 1))
        fi
    done < <(git submodule status --recursive 2>/dev/null || true)
fi

if [ "${nested_total}" -eq 0 ]; then
    # CRITICAL graceful path: nothing nested to validate is a PASS, never error.
    ok "nested submodules: 0 (nothing to check)"
else
    printf 'nested submodules: %d total, %d fully verified\n' "${nested_total}" "${nested_checked}"
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
