#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SPACECUE_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/SpaceCue.app"
CACHE="$BUILD_DIR/.swift-cache"
ARCH="$(uname -m)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
IDENTITY_NAME="SpaceCue Local Code Signing"
SIGN_IDENTITY="${SPACECUE_SIGN_IDENTITY:--}"
KEYCHAIN=""

if [[ "${SPACECUE_USE_LOCAL_KEYCHAIN:-0}" == "1" ]]; then
  SIGN_IDENTITY="$IDENTITY_NAME"
  KEYCHAIN="$("$ROOT/scripts/ensure-local-codesign.sh")"
fi

clear_bundle_xattrs() {
  /usr/bin/xattr -cr "$APP" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.ResourceFork "$APP" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.FinderInfo "$APP/Contents/MacOS/SpaceCue" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.ResourceFork "$APP/Contents/MacOS/SpaceCue" 2>/dev/null || true
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
touch "$APP/Contents/Resources/.keep"

export CLANG_MODULE_CACHE_PATH="$CACHE"
export SWIFT_MODULE_CACHE_PATH="$CACHE"

swiftc \
  -swift-version 5 \
  -target "$ARCH-apple-macosx14.0" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework CoreGraphics \
  "$ROOT"/Sources/SpaceCue/*.swift \
  -o "$APP/Contents/MacOS/SpaceCue"

clear_bundle_xattrs
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
if [[ -n "$KEYCHAIN" ]]; then
  SIGN_ARGS=(--force --deep --keychain "$KEYCHAIN" --sign "$SIGN_IDENTITY")
fi

if ! codesign "${SIGN_ARGS[@]}" "$APP"; then
  echo "warning: app bundle signing failed, signing executable only" >&2
  clear_bundle_xattrs
  if [[ -n "$KEYCHAIN" ]]; then
    codesign --force --keychain "$KEYCHAIN" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/SpaceCue"
  else
    codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/SpaceCue"
  fi
fi
clear_bundle_xattrs
codesign --verify --deep --strict "$APP" 2>/dev/null || codesign --verify --strict "$APP/Contents/MacOS/SpaceCue"

echo "$APP"
