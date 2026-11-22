#!/bin/sh
set -eu

cd "$(dirname "$0")"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

app="$build_dir/MX Mouse Buttons.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/"
cp .env.example "$app/Contents/Resources/defaults.env"
export MACOSX_DEPLOYMENT_TARGET=14.0
xcrun swiftc -module-cache-path "$build_dir/Modules" -swift-version 6 -O -warnings-as-errors MXMouseButtons.swift \
    ButtonBindings.swift \
    -o "$app/Contents/MacOS/MXMouseButtons"
"$app/Contents/MacOS/MXMouseButtons" --validate-config
codesign --force --sign - "$app"
codesign --verify --strict "$app"

target="${1:-/Applications/MX Mouse Buttons.app}"
mkdir -p "$(dirname "$target")"
if [ -e "$target" ]; then
    echo "Already exists: $target" >&2
    exit 1
fi
ditto --noextattr "$app" "$target"
xattr -r -d com.apple.FinderInfo "$target" 2>/dev/null || true
codesign --verify --strict "$target"
printf '%s\n' "$target"
