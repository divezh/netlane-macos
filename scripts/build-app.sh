#!/bin/bash
# Builds dist/Netlane.app and dist/Netlane-macos.zip (universal: Apple Silicon + Intel).
#   scripts/build-app.sh            build, test, package
#   scripts/build-app.sh --no-test  skip the tests
# Needs macOS 13+ with Xcode or the Command Line Tools. The app is signed ad hoc (no Apple Developer ID).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/NetlaneCore/Support.swift | head -1)
ENGINE_URL=$(sed -n 's/.*archiveUrl = "\(.*\)"/\1/p' Sources/NetlaneCore/Session.swift)
ENGINE_SHA=$(sed -n 's/.*archiveSha256 = "\(.*\)"/\1/p' Sources/NetlaneCore/Session.swift)
[ -n "$VERSION" ] && [ -n "$ENGINE_URL" ] && [ -n "$ENGINE_SHA" ] || { echo "cannot read version or engine pin" >&2; exit 1; }
echo "Netlane $VERSION"

if [ "${1:-}" != "--no-test" ]; then swift test; fi

# One build per architecture, joined with lipo: this also works without full Xcode.
for arch in arm64 x86_64; do swift build -c release --triple "$arch-apple-macosx13.0"; done

APP=dist/Netlane.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
lipo -create .build/arm64-apple-macosx/release/Netlane .build/x86_64-apple-macosx/release/Netlane -output "$APP/Contents/MacOS/Netlane"
lipo -create .build/arm64-apple-macosx/release/NetlaneHelper .build/x86_64-apple-macosx/release/NetlaneHelper -output "$APP/Contents/Resources/NetlaneHelper"
cp scripts/install-helper.sh scripts/uninstall-helper.sh "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
sed "s/@VERSION@/$VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"

# The pinned engine: the official TrustTunnel client, checked by SHA-256 before it is unpacked.
CACHE=.build/engine
mkdir -p "$CACHE"
ARCHIVE="$CACHE/$(basename "$ENGINE_URL")"
[ -f "$ARCHIVE" ] || curl -fsSL --retry 3 -o "$ARCHIVE" "$ENGINE_URL"
ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
if [ "$ACTUAL" != "$ENGINE_SHA" ]; then rm -f "$ARCHIVE"; echo "engine archive hash mismatch: $ACTUAL" >&2; exit 1; fi
rm -rf "$CACHE/unpacked"; mkdir -p "$CACHE/unpacked"
tar -xzf "$ARCHIVE" -C "$CACHE/unpacked"
ENGINE=$(find "$CACHE/unpacked" -type f -name trusttunnel_client | head -1)
[ -n "$ENGINE" ] || { echo "trusttunnel_client is not in the archive" >&2; exit 1; }
cp "$ENGINE" "$APP/Contents/Resources/engine/trusttunnel_client"
chmod 755 "$APP/Contents/Resources/engine/trusttunnel_client"
LICENSE_FILE=$(find "$CACHE/unpacked" -type f -iname 'LICENSE*' | head -1)
[ -z "$LICENSE_FILE" ] || cp "$LICENSE_FILE" "$APP/Contents/Resources/engine/LICENSE.txt"

# Icon: assets/icon-1024.png when present (sharp at every size), else the 128 px one.
MASTER=assets/icon.png
[ -f assets/icon-1024.png ] && MASTER=assets/icon-1024.png
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signatures: Apple Silicon refuses unsigned code. The engine keeps its publisher's signature if it has one.
codesign --force --sign - "$APP/Contents/Resources/NetlaneHelper"
codesign --verify "$APP/Contents/Resources/engine/trusttunnel_client" 2>/dev/null || codesign --force --sign - "$APP/Contents/Resources/engine/trusttunnel_client"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" dist/Netlane-macos.zip
(cd dist && shasum -a 256 Netlane-macos.zip > Netlane-macos.zip.sha256 && cat Netlane-macos.zip.sha256)
echo "Done: $APP"
