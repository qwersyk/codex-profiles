#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.build/tests"
SDK_ARGS=()
if [[ -n "${CODEX_PROFILES_SDK:-}" ]]; then
    SDK_ARGS=(-sdk "$CODEX_PROFILES_SDK")
fi
swiftc "${SDK_ARGS[@]}" -enable-testing -emit-library -emit-module -module-name RelayCore \
    -emit-module-path "$ROOT_DIR/.build/tests/RelayCore.swiftmodule" \
    -o "$ROOT_DIR/.build/tests/libRelayCore.dylib" "$ROOT_DIR"/Sources/RelayCore/*.swift
swiftc "${SDK_ARGS[@]}" -I "$ROOT_DIR/.build/tests" -L "$ROOT_DIR/.build/tests" -lRelayCore \
    -Xlinker -rpath -Xlinker "$ROOT_DIR/.build/tests" -o "$ROOT_DIR/.build/tests/profile-tests" \
    "$ROOT_DIR/Sources/CodexProfilesApp/AppModel.swift" \
    "$ROOT_DIR/Sources/CodexProfilesApp/RemoteModel.swift" \
    "$ROOT_DIR/Sources/CodexProfilesApp/RemoteView.swift" \
    "$ROOT_DIR/Sources/CodexProfilesApp/SessionRenewal.swift" \
    "$ROOT_DIR/Sources/CodexProfilesApp/AccountUsage.swift" \
    "$ROOT_DIR/Tests/CodexProfilesTests/ProfileStoreTests.swift" \
    "$ROOT_DIR/Tests/CodexProfilesTests/SessionRenewalTests.swift" \
    "$ROOT_DIR/Tests/CodexProfilesTests/RemoteTests.swift" \
    "$ROOT_DIR/Tests/CodexProfilesTests/AccountPickerTests.swift"
"$ROOT_DIR/.build/tests/profile-tests"
