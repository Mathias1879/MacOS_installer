#!/usr/bin/env bash
# Runs the test suite, working around Command Line Tools shipping the Swift
# Testing macro plugin in a subdirectory SwiftPM does not search.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_TESTING_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"

if [[ -d "${CLT_TESTING_PLUGINS}" ]]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "${CLT_TESTING_PLUGINS}" "$@"
fi

exec swift test "$@"
