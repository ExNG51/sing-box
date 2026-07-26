#!/usr/bin/env bash
set -uo pipefail

# P2-03/P3-03: shellcheck is wired into CI (informational) and the real
# static errors (SC2148 shebang, SC1007 empty-assignment) are fixed.

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# CI must include a shellcheck step
grep -q 'shellcheck -x' "$REPO_ROOT/.github/workflows/release.yml" || \
    fail "release.yml must include a shellcheck -x step"

# help.sh must have a shebang (SC2148 fix)
head -1 "$REPO_ROOT/src/help.sh" | grep -q '^#!/bin/bash' || \
    fail "src/help.sh must start with a shebang (SC2148 fix)"

# tuic_port_hopping.sh must not use the SC1007 empty-assignment pattern
if grep -qE 'local [a-z_]+= [a-z_]+=' "$REPO_ROOT/src/tuic_port_hopping.sh"; then
    fail "src/tuic_port_hopping.sh must not use 'var= var=' (SC1007)"
fi
grep -q "delete_yes='' delete_confirm=''" "$REPO_ROOT/src/tuic_port_hopping.sh" || \
    fail "src/tuic_port_hopping.sh must use '' empty-assignment style"

# If shellcheck is available locally, verify the real errors are gone.
if command -v shellcheck >/dev/null 2>&1; then
    sc2148=$(shellcheck -x "$REPO_ROOT/src/help.sh" 2>&1 | grep -c "SC2148" || true)
    [[ $sc2148 -eq 0 ]] || fail "src/help.sh must have no SC2148 (got $sc2148)"
    sc1007=$(shellcheck -x "$REPO_ROOT/src/tuic_port_hopping.sh" 2>&1 | grep -c "SC1007" || true)
    [[ $sc1007 -eq 0 ]] || fail "src/tuic_port_hopping.sh must have no SC1007 (got $sc1007)"

    for test_file in \
        tests/client-url-compatibility.sh \
        tests/process-detection-cleanup.sh \
        tests/ci-version-extraction.sh \
        tests/lib/version.sh; do
        shellcheck -x "$REPO_ROOT/$test_file" || \
            fail "$test_file must pass shellcheck -x"
    done
fi

printf '[PASS] shellcheck baseline checks\n'
