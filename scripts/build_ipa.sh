#!/usr/bin/env bash
# Builds MediaDeck for device without code signing, fakesigns it with ldid using the
# entitlements in Support/MediaDeck.entitlements, and packages build/MediaDeck.ipa
# (installable with TrollStore). Run on macOS after `xcodegen generate`.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
LOG=build/xcodebuild.log

if ! xcodebuild \
    -project MediaDeck.xcodeproj \
    -scheme MediaDeck \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > "$LOG" 2>&1; then
  echo "::group::Compiler errors"
  grep -E "error:|fatal error" -A4 "$LOG" | head -400 || true
  echo "::endgroup::"
  echo "----- tail of build log -----"
  tail -60 "$LOG"
  exit 1
fi

APP=build/dd/Build/Products/Release-iphoneos/MediaDeck.app
test -d "$APP"

# Fakesign with entitlements (TrollStore also accepts this; it re-signs on install).
ldid -SSupport/MediaDeck.entitlements "$APP/MediaDeck"

rm -rf build/Payload build/MediaDeck.ipa
mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry MediaDeck.ipa Payload)
ls -la build/MediaDeck.ipa
echo "IPA ready: build/MediaDeck.ipa"
