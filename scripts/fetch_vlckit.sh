#!/usr/bin/env bash
# Downloads VideoLAN's MobileVLCKit 3.7.4 binary (the archive its CocoaPods spec points to),
# checks its SHA-256, and keeps only the arm64 device slice in Vendor/MobileVLCKit.framework
# (the full fat binary is about 104 MB; arm64 alone is about 39 MB).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Vendor/MobileVLCKit.framework
if [ -f "$OUT/MobileVLCKit" ]; then echo "MobileVLCKit already present"; exit 0; fi
URL=https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz
SHA=c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/vlc.tar.xz" "$URL"
echo "$SHA  $TMP/vlc.tar.xz" | shasum -a 256 -c -
tar -xJf "$TMP/vlc.tar.xz" -C "$TMP" "MobileVLCKit-binary/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s"
mkdir -p Vendor
rm -rf "$OUT"
cp -R "$TMP/MobileVLCKit-binary/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework" "$OUT"
lipo "$OUT/MobileVLCKit" -thin arm64 -output "$OUT/MobileVLCKit.arm64"
mv "$OUT/MobileVLCKit.arm64" "$OUT/MobileVLCKit"
rm -rf "$TMP"
ls -la "$OUT/MobileVLCKit"
