#!/usr/bin/env bash
# Local CI. No hosted runners — all verification happens on this machine.
set -euo pipefail

cd "$(dirname "$0")/.."

# Command Line Tools ship the Swift Testing macro plugin in a path SwiftPM
# does not search by default (see scripts/test.sh for the full explanation).
# --build-tests compiles the test target, so it needs the same workaround;
# a plain word-split (not an array) keeps this working under bash 3.2's
# `set -u` + empty-array bug, and the path never contains spaces.
CLT_TESTING_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
plugin_path_flags=""
if [[ -d "${CLT_TESTING_PLUGINS}" ]]; then
    plugin_path_flags="-Xswiftc -plugin-path -Xswiftc ${CLT_TESTING_PLUGINS}"
fi

echo "==> Building"
# shellcheck disable=SC2086
swift build --build-tests ${plugin_path_flags}

echo "==> Testing with coverage"
# Routed through scripts/test.sh, which carries the same guard, rather than
# calling `swift test` directly.
./scripts/test.sh --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="${BIN_PATH}/codecov/default.profdata"
XCTEST_BUNDLE="${BIN_PATH}/MacOSInstallerKitTests.xctest"
TEST_BINARY="${XCTEST_BUNDLE}/Contents/MacOS/MacOSInstallerKitTests"

if [[ ! -f "${PROFDATA}" ]]; then
    echo "FAIL: no coverage profile at ${PROFDATA}" >&2
    exit 1
fi

if [[ ! -x "${TEST_BINARY}" ]]; then
    echo "FAIL: no test binary at ${TEST_BINARY}" >&2
    exit 1
fi

echo "==> Coverage for MacOSInstallerKit"
xcrun llvm-cov report \
    "${TEST_BINARY}" \
    -instr-profile "${PROFDATA}" \
    -ignore-filename-regex='(Tests|\.build)/' \
    | tee /tmp/macos-installer-coverage.txt

TOTAL="$(awk '/^TOTAL/ {gsub(/%/,"",$10); print $10}' /tmp/macos-installer-coverage.txt)"

if [[ -z "${TOTAL}" ]]; then
    echo "FAIL: could not parse total line coverage from llvm-cov output" >&2
    exit 1
fi

echo "==> Total line coverage: ${TOTAL}%"

if awk "BEGIN {exit !(${TOTAL} < 80)}"; then
    echo "FAIL: coverage ${TOTAL}% is below the 80% minimum" >&2
    exit 1
fi

echo "==> All checks passed"
