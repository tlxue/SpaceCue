#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${SPACECUE_INSTALL_DIR:-$HOME/Applications}"
TMP_BUILD="/private/tmp/SpaceCue-build"
APP="$INSTALL_DIR/SpaceCue.app"

rm -rf "$TMP_BUILD"
mkdir -p "$TMP_BUILD" "$INSTALL_DIR"

SPACECUE_BUILD_DIR="$TMP_BUILD" \
  SPACECUE_USE_LOCAL_KEYCHAIN="${SPACECUE_USE_LOCAL_KEYCHAIN:-1}" \
  "$ROOT/build.sh" >/dev/null

rm -rf "$APP"
ditto "$TMP_BUILD/SpaceCue.app" "$APP"
/usr/bin/xattr -cr "$APP" 2>/dev/null || true

echo "$APP"
