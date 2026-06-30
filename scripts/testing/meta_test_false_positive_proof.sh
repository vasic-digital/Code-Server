#!/usr/bin/env bash
#
# scripts/testing/meta_test_false_positive_proof.sh
#
# Paired §1.1 mutation proof for the inheritance GATE
# (tests/pre_build_verification.sh).
#
# A gate that always passes is worthless. This script proves the gate is a
# TRUE NEGATIVE detector: it provably FAILS when the §11.4 forensic anchor is
# removed from constitution/Constitution.md. Two modes:
#
#   (A) Preferred: delegate to the constitution's own meta-test harness
#         bash constitution/meta_test_inheritance.sh "bash tests/pre_build_verification.sh"
#       The harness deletes the §11.4 anchor line, runs the gate, asserts the
#       gate returned NON-ZERO, then restores via its own trap. It exits 0 when
#       the gate correctly failed -> we assert that exit code is 0.
#
#   (B) Fallback [CM-CONSTITUTION-INHERITANCE]: if the harness is absent we
#       perform the mutation ourselves -- back up Constitution.md, set a restore
#       trap, strip the §11.4 anchor line, run the gate, and assert it now
#       returns NON-ZERO. The trap restores the pristine file no matter what.
#
# Prints a clear PASS/FAIL and exits 0 ONLY if the gate provably catches the
# missing-anchor regression.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Resolve the repository root (git first, script-dir fallback).
# This script lives in <repo>/scripts/testing/, so repo root is two levels up.
# --------------------------------------------------------------------------
if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "${repo_root}" ]; then
    cd "${repo_root}"
else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
    cd "${script_dir}/../.." >/dev/null 2>&1 || cd "${script_dir}"
fi

readonly GATE_REL="tests/pre_build_verification.sh"
readonly HARNESS_REL="constitution/meta_test_inheritance.sh"
readonly CONSTITUTION_REL="constitution/Constitution.md"
# '### ' prefix required so the fallback mutation removes the heading the gate
# checks (not just the Table-of-Contents copy) — keeps this a real §1.1 proof.
readonly ANCHOR='### §11.4 End-user quality guarantee — forensic anchor'

pass() { printf 'PASS: %s\n' "$1"; exit 0; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The gate must exist for any proof to be meaningful: otherwise a missing gate
# would non-zero-exit and masquerade as "correctly caught the mutation".
[ -f "${GATE_REL}" ] \
    || fail "gate script '${GATE_REL}' not found; cannot run mutation proof"

# --------------------------------------------------------------------------
# Mode (A): constitution-provided meta-test harness.
# --------------------------------------------------------------------------
if [ -f "${HARNESS_REL}" ]; then
    printf 'Running constitution meta-test harness against the gate...\n'
    printf '  $ bash %s "bash %s"\n' "${HARNESS_REL}" "${GATE_REL}"
    if bash "${HARNESS_REL}" "bash ${GATE_REL}"; then
        pass "constitution meta-test harness confirms the gate catches the §11.4 mutation"
    else
        fail "constitution meta-test harness reports the gate did NOT catch the §11.4 mutation (false-positive gate)"
    fi
fi

# --------------------------------------------------------------------------
# Mode (B): fallback local mutation proof  [CM-CONSTITUTION-INHERITANCE].
# --------------------------------------------------------------------------
printf '[CM-CONSTITUTION-INHERITANCE] constitution meta-test harness not found; running local mutation proof\n'

[ -f "${CONSTITUTION_REL}" ] \
    || fail "${CONSTITUTION_REL} not found; cannot mutate what does not exist"

# Sanity: the anchor must currently be present, else the "removal" is a no-op
# and the proof would be vacuous.
grep -qF -- "${ANCHOR}" "${CONSTITUTION_REL}" \
    || fail "${CONSTITUTION_REL} does not currently contain the §11.4 forensic anchor; cannot prove its removal is detected"

backup_file="$(mktemp "${TMPDIR:-/tmp}/constitution_backup.XXXXXX")"
cp -- "${CONSTITUTION_REL}" "${backup_file}"

restore() {
    # Restore the pristine constitution and clean up, regardless of outcome.
    if [ -f "${backup_file}" ]; then
        cp -- "${backup_file}" "${CONSTITUTION_REL}" 2>/dev/null || true
        rm -f -- "${backup_file}" 2>/dev/null || true
    fi
}
trap restore EXIT INT TERM

# Mutate: drop every line containing the forensic anchor. `grep -v` returns 1
# when it selects no lines (i.e. the file would be empty) which we tolerate;
# the post-condition check below is the real guarantee.
grep -vF -- "${ANCHOR}" "${backup_file}" > "${CONSTITUTION_REL}" || true

# Confirm the mutation actually took effect (defensive: independent of grep's
# exit status above).
if grep -qF -- "${ANCHOR}" "${CONSTITUTION_REL}"; then
    fail "mutation did not remove the §11.4 forensic anchor; proof is invalid"
fi

# Run the gate. We EXPECT it to fail (non-zero) now that the anchor is gone.
if bash "${GATE_REL}"; then
    fail "gate PASSED despite the §11.4 forensic anchor being removed (FALSE POSITIVE gate)"
else
    pass "gate correctly FAILED after the §11.4 forensic anchor was removed (mutation detected)"
fi
