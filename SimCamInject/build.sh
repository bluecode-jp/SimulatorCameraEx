#!/usr/bin/env bash
#
# build.sh — build the iOS Simulator injection dylibs.
#
# Produces (in $1, default build/inject; the Xcode build puts them in
# SimulatorCameraEx.app/Contents/Resources/SimCamInject):
#   SimCamLoader.dylib   DYLD_INSERT_LIBRARIES entry point (libSystem only)
#   SimCamInject.dylib   AVFoundation hooks + frame source + web page camera
#

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/../build/inject}"
mkdir -p "$OUT"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MIN_IOS="${MIN_IOS:-16.0}"
ARCHS=(-arch arm64 -arch x86_64)
COMMON=("${ARCHS[@]}" -isysroot "$SDK" -mios-simulator-version-min="$MIN_IOS" -dynamiclib -O2 -Wall)

xcrun --sdk iphonesimulator clang "${COMMON[@]}" \
    -install_name @rpath/SimCamLoader.dylib \
    "$HERE/SimCamLoader.c" -o "$OUT/SimCamLoader.dylib"

# The web page shim is compiled in as a byte array (SimCamWebShim_js[]).
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
(cd "$HERE" && xxd -i SimCamWebShim.js) > "$GEN/SimCamWebShim.js.h"

xcrun --sdk iphonesimulator clang "${COMMON[@]}" -fno-objc-arc -I "$GEN" \
    -install_name @rpath/SimCamInject.dylib \
    -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework QuartzCore -framework VideoToolbox -framework CoreGraphics -framework ImageIO -framework CoreMotion \
    "$HERE/SimCamInject.m" "$HERE/SimCamFrameSource.m" "$HERE/SimCamWeb.m" -o "$OUT/SimCamInject.dylib"

# SIGN_IDENTITY: the container app's identity when bundled (Xcode passes
# $EXPANDED_CODE_SIGN_IDENTITY), ad-hoc otherwise. Hardened runtime and a
# secure timestamp are what notarization requires of every nested Mach-O.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign -f -s - "$OUT/SimCamLoader.dylib" "$OUT/SimCamInject.dylib"
else
    codesign -f -s "$SIGN_IDENTITY" -o runtime ${SIGN_TIMESTAMP:---timestamp=none} \
        "$OUT/SimCamLoader.dylib" "$OUT/SimCamInject.dylib"
fi
echo "built: $OUT/SimCamLoader.dylib $OUT/SimCamInject.dylib"
