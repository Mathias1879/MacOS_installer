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

# Coverage is reported for MacOSInstallerKit (the library) and
# macos-installer (the executable) SEPARATELY, and only the library figure
# gates the build.
#
# Why: the test target depends on the macos-installer executable target (added
# in Task 5 so TargetMacPicker's retry loop could be tested), so the combined
# llvm-cov run has always included the executable's source files since then.
# The executable is deliberately thin wiring — CreateCommand documents itself
# as excluded from coverage — so averaging it into one TOTAL dilutes the
# number the gate was calibrated against: a real library regression from
# ~96% to ~88% would still clear an 80% combined gate once ~300 untested
# wiring lines are sitting in the denominator. Gating on the library alone
# keeps the threshold meaningful.
#
# -ignore-filename-regex additionally excludes the other target's directory
# (llvm-cov prints paths as "<TargetName>/<File>.swift" here) so each report
# covers exactly one target.
LIB_IGNORE_REGEX='(Tests|\.build)/|(^|/)macos-installer/'
EXE_IGNORE_REGEX='(Tests|\.build)/|(^|/)MacOSInstallerKit/'
COMBINED_IGNORE_REGEX='(Tests|\.build)/'

# The library has sat in the mid-90s for the whole project (95.93% at Task 4,
# 95.82% as of this round). 93% leaves room for normal single-digit-line
# fluctuation while still being tight enough that a genuine regression trips
# it rather than being absorbed.
LIBRARY_COVERAGE_MINIMUM=93

parse_total_line_coverage() {
    awk '/^TOTAL/ {gsub(/%/,"",$10); print $10}' "$1"
}

echo "==> Coverage for MacOSInstallerKit (library — GATED)"
xcrun llvm-cov report \
    "${TEST_BINARY}" \
    -instr-profile "${PROFDATA}" \
    -ignore-filename-regex="${LIB_IGNORE_REGEX}" \
    | tee /tmp/macos-installer-coverage-library.txt

LIBRARY_TOTAL="$(parse_total_line_coverage /tmp/macos-installer-coverage-library.txt)"

if [[ -z "${LIBRARY_TOTAL}" ]]; then
    echo "FAIL: could not parse library total line coverage from llvm-cov output" >&2
    exit 1
fi

echo "==> MacOSInstallerKit line coverage: ${LIBRARY_TOTAL}%"

echo "==> Coverage for macos-installer (executable — informational only, NOT gated)"
echo "    Thin wiring by design (see CreateCommand.swift's doc comment);"
echo "    low numbers here are expected and do not indicate rot."
xcrun llvm-cov report \
    "${TEST_BINARY}" \
    -instr-profile "${PROFDATA}" \
    -ignore-filename-regex="${EXE_IGNORE_REGEX}" \
    | tee /tmp/macos-installer-coverage-executable.txt

EXECUTABLE_TOTAL="$(parse_total_line_coverage /tmp/macos-installer-coverage-executable.txt)"

if [[ -z "${EXECUTABLE_TOTAL}" ]]; then
    echo "FAIL: could not parse executable total line coverage from llvm-cov output" >&2
    exit 1
fi

echo "==> macos-installer line coverage: ${EXECUTABLE_TOTAL}% (informational)"

echo "==> Combined coverage (library + executable — informational only, NOT gated)"
xcrun llvm-cov report \
    "${TEST_BINARY}" \
    -instr-profile "${PROFDATA}" \
    -ignore-filename-regex="${COMBINED_IGNORE_REGEX}" \
    | tee /tmp/macos-installer-coverage-combined.txt

COMBINED_TOTAL="$(parse_total_line_coverage /tmp/macos-installer-coverage-combined.txt)"

if [[ -z "${COMBINED_TOTAL}" ]]; then
    echo "FAIL: could not parse combined total line coverage from llvm-cov output" >&2
    exit 1
fi

echo "==> Combined line coverage: ${COMBINED_TOTAL}% (informational)"

if awk "BEGIN {exit !(${LIBRARY_TOTAL} < ${LIBRARY_COVERAGE_MINIMUM})}"; then
    echo "FAIL: MacOSInstallerKit coverage ${LIBRARY_TOTAL}% is below the ${LIBRARY_COVERAGE_MINIMUM}% minimum" >&2
    exit 1
fi

echo "==> All checks passed"
