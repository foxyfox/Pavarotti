#!/bin/zsh
# Build Pavarotti (Release) with a stable signature and install it to /Applications.
# Usage: scripts/fork/build-and-install.sh [--no-install]
set -euo pipefail

ROOT="${0:A:h:h:h}"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Pavarotti.app"
BUNDLE_ID="de.foxagon.pavarotti"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Sign with a stable identity so macOS keeps privacy permissions across rebuilds.
# Create it once in Keychain Access (see scripts/fork/README.md); falls back to ad-hoc.
SIGN_IDENTITY="${PAVAROTTI_SIGN_IDENTITY:-Pavarotti Signing}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  echo "Signing identity '$SIGN_IDENTITY' not found, signing ad-hoc (permissions reset on every build)" >&2
  SIGN_IDENTITY="-"
fi

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen not found, run 'make bootstrap' first" >&2
  exit 1
fi

cd "$ROOT"
mkdir -p "$ROOT/build"
LOG="$ROOT/build/xcodebuild.log"
(cd App && xcodegen generate --quiet)
xcodebuild \
  -project App/Biscotti.xcodeproj \
  -scheme Biscotti \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build > "$LOG" 2>&1 || {
    grep -E "error:|BUILD FAILED" "$LOG" | head -40 >&2
    echo "Build failed, full log: $LOG" >&2
    exit 1
  }

# Sign inside-out. Each XPC service and the app keep their own entitlements,
# which a single `codesign --deep` would drop.
sign() { codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$@"; }
sign_frameworks() {
  local item
  for item in "$1"/Contents/Frameworks/*(N); do sign "$item"; done
}
for xpc in "$APP"/Contents/XPCServices/*.xpc(N); do
  name="${xpc:t:r}"
  sign_frameworks "$xpc"
  sign --entitlements "$ROOT/XPCServices/$name/$name.entitlements" "$xpc"
done
sign_frameworks "$APP"
sign --entitlements "$ROOT/App/Biscotti.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"

[[ "${1:-}" == "--no-install" ]] && exit 0

osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
sleep 2
rm -rf /Applications/Pavarotti.app
ditto "$APP" /Applications/Pavarotti.app
echo "Installed: /Applications/Pavarotti.app"
open /Applications/Pavarotti.app
