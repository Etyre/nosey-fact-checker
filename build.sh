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
# Copied files can carry extended attributes (Finder info, provenance) that make codesign refuse
# with "resource fork, Finder information, or similar detritus not allowed". Strip them first.
xattr -cr "$BUNDLE"
if [ -n "$IDENTITY" ]; then
  echo "▸ codesign with: $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE"
  # A signature without the team ID means macOS will treat every rebuild as a new app and
  # re-ask for Screen Recording. Fail loudly rather than ship that.
  SIG_INFO="$(codesign -dv "$BUNDLE" 2>&1 || true)"
  if ! echo "$SIG_INFO" | grep "^TeamIdentifier=[A-Z0-9]" >/dev/null; then
    echo "✗ signature is missing the team identifier; refusing to continue" >&2
    codesign -dv "$BUNDLE" 2>&1 | grep -E "Identifier|Authority" >&2
    exit 1
  fi
else
  echo "▸ codesign ad-hoc (no Apple Development identity found; Screen Recording will re-prompt after each rebuild)"
  codesign --force --sign - "$BUNDLE"
fi
codesign -dv "$BUNDLE" 2>&1 | grep -E "^(Identifier|TeamIdentifier)=" | sed 's/^/▸ /'
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
