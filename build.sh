#!/bin/bash
# Build Nosey.app. Usage: ./build.sh [--install] [--run]
#   --install  copy the app to ~/Applications
#   --run      launch the app after building
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Nosey"
BUNDLE="build/$APP_NAME.app"

echo "▸ swift build -c release"
swift build -c release 2>&1 | grep -v "^\[" | tail -20

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/NoseyFactChecker" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Prefer a real Apple Development identity so macOS privacy grants (Screen Recording,
# Notifications) survive rebuilds. Fall back to ad-hoc signing.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ]; then
  echo "▸ codesign with: $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE"
else
  echo "▸ codesign ad-hoc (no Apple Development identity found)"
  codesign --force --sign - "$BUNDLE"
fi
echo "▸ built $BUNDLE"

TARGET="$BUNDLE"
for arg in "$@"; do
  case "$arg" in
    --install)
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/$APP_NAME.app"
      cp -R "$BUNDLE" "$HOME/Applications/$APP_NAME.app"
      TARGET="$HOME/Applications/$APP_NAME.app"
      echo "▸ installed to $TARGET"
      ;;
  esac
done
for arg in "$@"; do
  case "$arg" in
    --run)
      pkill -x "$APP_NAME" 2>/dev/null || true
      sleep 0.5
      open "$TARGET"
      echo "▸ launched $TARGET"
      ;;
  esac
done
