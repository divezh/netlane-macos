#!/bin/bash
# Builds the Netlane engine for macOS: TrustTunnel Client at a pinned commit with our patches
#   0001 — per-application routing and kill-switch retention (shared with the Windows client),
#   0002 — the macOS part: finding the process that owns a connection (libproc),
#   0003 — dns_all_through_vpn: every DNS query to the configured servers through the VPN.
# Output: engine/dist/trusttunnel_client (universal: arm64 + x86_64) and engine/dist/LICENSE.
#
# Needs: Xcode or Command Line Tools, cmake, ninja, python3, rustup (installs the pinned toolchain).
#   brew install cmake ninja && curl -sSf https://sh.rustup.rs | sh -s -- -y
# First build takes long (Conan builds OpenSSL and the other dependencies); later ones reuse the cache.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ENGINE_SOURCE:-$ROOT/.build/engine-src}"
COMMIT=067deb837ed994d6ae902e3bb40b69f6266af216
VERSION_LABEL="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' "$ROOT/Sources/NetlaneCore/Session.swift" | head -1)"
OUT="$ROOT/engine/dist"

if [ ! -d "$SRC/.git" ]; then
    git clone --branch v1.1.12 --depth 1 https://github.com/TrustTunnel/TrustTunnelClient.git "$SRC"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "unexpected upstream commit" >&2; exit 1; }

# Patches go onto a clean tree each time; a previous build's tree is reset first (the build cache stays).
git -C "$SRC" reset -q --hard "$COMMIT"
git -C "$SRC" clean -qfd -e 'build_*' -e env
for patch in "$ROOT"/engine/upstream/*.patch; do
    git -C "$SRC" apply --check "$patch"
    git -C "$SRC" apply "$patch"
done

cd "$SRC"
python3 -m venv env
# shellcheck disable=SC1091
. env/bin/activate
pip install -q -r requirements.txt "conan>=2.0.5,<3"
export SKIP_VENV=1 TT_CLIENT_VERSION="$VERSION_LABEL"
python3 scripts/bootstrap_conan_deps.py
conan profile detect --exist-ok >/dev/null

for arch in arm64 x86_64; do
    make PRESET=clang-relwithdebinfo ARCH="$arch" BUILD_DIR="build_$arch" SKIP_BOOTSTRAP=1 build_trusttunnel_client
done
# Unit tests of the routing code on this Mac's own architecture (real sockets, real libproc).
HOST="$(uname -m)"
cmake --build "build_$HOST" --target test_application_routes
"build_$HOST/trusttunnel/test_application_routes"

mkdir -p "$OUT"
lipo -create -output "$OUT/trusttunnel_client" build_arm64/trusttunnel/trusttunnel_client build_x86_64/trusttunnel/trusttunnel_client
strip "$OUT/trusttunnel_client"
cp LICENSE "$OUT/LICENSE"
lipo -info "$OUT/trusttunnel_client"
echo "Engine $VERSION_LABEL: $OUT/trusttunnel_client"
