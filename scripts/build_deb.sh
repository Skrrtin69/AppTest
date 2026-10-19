#!/usr/bin/env bash
# Fallback packaging: wraps the already-built, fakesigned MediaDeck.app into a .deb.
# Produces a rootless-layout package (/var/jb/Applications). roothide's package
# manager converts rootless debs automatically. Run after build_ipa.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Payload/MediaDeck.app
test -d "$APP" || { echo "Run build_ipa.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")

ROOT=build/deb
rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/var/jb/Applications"
cp -R "$APP" "$ROOT/var/jb/Applications/"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: com.skrrtin69.mediadeck
Name: MediaDeck
Version: $VERSION
Architecture: iphoneos-arm64
Description: Config-driven media browser
Maintainer: Skrrtin69
Author: Skrrtin69
Section: Utilities
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
uicache -p /var/jb/Applications/MediaDeck.app 2>/dev/null || uicache -a 2>/dev/null || true
exit 0
EOF
chmod 755 "$ROOT/DEBIAN/postinst"

# dpkg-deb is not on macOS runners by default; build the ar archive by hand.
WORK=build/debwork
rm -rf "$WORK"; mkdir -p "$WORK"
echo "2.0" > "$WORK/debian-binary"
(cd "$ROOT/DEBIAN" && tar --format=ustar -czf "../../debwork/control.tar.gz" .)
(cd "$ROOT" && tar --format=ustar --exclude=./DEBIAN -czf "../debwork/data.tar.gz" ./var)
OUT="build/mediadeck_${VERSION}_iphoneos-arm64.deb"
rm -f "$OUT"
(cd "$WORK" && ar -rc "../../$OUT" debian-binary control.tar.gz data.tar.gz)
ls -la "$OUT"
