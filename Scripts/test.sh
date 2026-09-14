#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.build/tests"
SDK_ARGS=()
if [[ -n "${CODEX_PROFILES_SDK:-}" ]]; then
    SDK_ARGS=(-sdk "$CODEX_PROFILES_SDK")
fi
swiftc "${SDK_ARGS[@]}" -o "$ROOT_DIR/.build/tests/profile-tests" \
    "$ROOT_DIR/Sources/CodexProfilesApp/AppModel.swift" \
    "$ROOT_DIR/Sources/CodexProfilesApp/SessionRenewal.swift" \
    "$ROOT_DIR/Sources/CodexProfilesApp/AccountUsage.swift" \
    "$ROOT_DIR/Tests/CodexProfilesTests/ProfileStoreTests.swift" \
    "$ROOT_DIR/Tests/CodexProfilesTests/SessionRenewalTests.swift"
"$ROOT_DIR/.build/tests/profile-tests"
