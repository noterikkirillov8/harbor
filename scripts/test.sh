#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harbor-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
flags=()
if [[ ${CODEX_SANDBOX:-} == seatbelt ]]; then flags+=(-Xfrontend -disable-sandbox); fi
swiftc ${flags[@]+"${flags[@]}"} -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$TEST_DIR/modules" \
    Harbor/Sources/Core/*.swift Harbor/Sources/UI/{Kit,Model}.swift tests/CoreTests.swift tests/IntroFlowTests.swift -o "$TEST_DIR/t"
"$TEST_DIR/t"
