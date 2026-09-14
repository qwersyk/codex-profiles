#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Profiles"
EXEC_NAME="CodexProfilesApp"
ASSETS_DIR="$ROOT_DIR/Assets"
ICONSET_DIR="$ASSETS_DIR/AppIcon.iconset"
ICON_PATH="$ASSETS_DIR/CodexProfiles.icns"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

mkdir -p "$ASSETS_DIR" "$DIST_DIR"
rm -rf "$ICONSET_DIR" "$ICON_PATH"
SWIFT_BUILD_ARGS=()
SWIFTC_ARGS=()
if [[ -n "${CODEX_PROFILES_SDK:-}" ]]; then
    SWIFT_BUILD_ARGS=(--sdk "$CODEX_PROFILES_SDK" --build-system native)
    SWIFTC_ARGS=(-sdk "$CODEX_PROFILES_SDK")
fi
swiftc "${SWIFTC_ARGS[@]}" -framework AppKit -o "$ASSETS_DIR/icon-generator" "$ROOT_DIR/Scripts/generate_icon.swift"
"$ASSETS_DIR/icon-generator" "$ICONSET_DIR" "$ICON_PATH"
rm "$ASSETS_DIR/icon-generator"

cd "$ROOT_DIR"
swift build "${SWIFT_BUILD_ARGS[@]}" -c release --product "$EXEC_NAME"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/CodexProfiles.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Profiles</string>
    <key>CFBundleExecutable</key>
    <string>CodexProfilesApp</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.qwersyk.codexprofiles</string>
    <key>CFBundleIconFile</key>
    <string>CodexProfiles</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Profiles</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>JSON</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.json</string>
            </array>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>qwersyk</string>
    <key>CFBundleShortVersionString</key>
    <string>1.12</string>
    <key>CFBundleVersion</key>
    <string>15</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

chmod +x "$APP_DIR/Contents/MacOS/$EXEC_NAME"
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
