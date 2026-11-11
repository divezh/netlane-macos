#!/bin/bash
# Builds dist/Netlane.app and dist/Netlane-macos.zip (universal: Apple Silicon + Intel).
#   scripts/build-app.sh            build, test, package
#   scripts/build-app.sh --no-test  skip the tests
# Needs macOS 13+ with Xcode or the Command Line Tools. The app is signed ad hoc (no Apple Developer ID).
# Without engine/dist/trusttunnel_client the engine is built first (engine/build-engine.sh, long the first time).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/NetlaneCore/Support.swift | head -1)
[ -n "$VERSION" ] || { echo "cannot read the version" >&2; exit 1; }
# The engine with application routing (engine/build-engine.sh). ENGINE_BINARY points to a ready one (CI).
ENGINE="${ENGINE_BINARY:-engine/dist/trusttunnel_client}"
if [ ! -f "$ENGINE" ]; then engine/build-engine.sh; ENGINE=engine/dist/trusttunnel_client; fi
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

cp "$ENGINE" "$APP/Contents/Resources/engine/trusttunnel_client"
chmod 755 "$APP/Contents/Resources/engine/trusttunnel_client"
ENGINE_LICENSE="$(dirname "$ENGINE")/LICENSE"
[ -f "$ENGINE_LICENSE" ] && cp "$ENGINE_LICENSE" "$APP/Contents/Resources/engine/LICENSE.txt"

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

# Ad-hoc signatures: Apple Silicon refuses unsigned code.
codesign --force --sign - "$APP/Contents/Resources/NetlaneHelper"
codesign --force --sign - "$APP/Contents/Resources/engine/trusttunnel_client"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" dist/Netlane-macos.zip

# Installer: puts the app into /Applications, installs the helper, opens Netlane (packaging/pkg-scripts).
PKGROOT=.build/pkgroot
rm -rf "$PKGROOT"; mkdir -p "$PKGROOT/Applications"
ditto "$APP" "$PKGROOT/Applications/Netlane.app"
pkgbuild --analyze --root "$PKGROOT" .build/components.plist >/dev/null
# Not relocatable: always /Applications, never «wherever another copy happens to be».
plutil -replace 0.BundleIsRelocatable -bool NO .build/components.plist
pkgbuild --root "$PKGROOT" --component-plist .build/components.plist --identifier io.github.divezh.netlane \
    --version "$VERSION" --install-location / --scripts packaging/pkg-scripts .build/Netlane-component.pkg
sed "s/@VERSION@/$VERSION/g" packaging/distribution.xml > .build/distribution.xml
productbuild --distribution .build/distribution.xml --resources packaging/resources --package-path .build dist/Netlane-macos.pkg

(cd dist && shasum -a 256 Netlane-macos.zip > Netlane-macos.zip.sha256 && shasum -a 256 Netlane-macos.pkg > Netlane-macos.pkg.sha256 && cat ./*.sha256)
echo "Done: $APP"
