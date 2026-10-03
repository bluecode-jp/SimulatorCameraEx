#!/usr/bin/env bash
#
# test-inject.sh — 注入ライブラリ（SimCamInject）を、起動中の iOS シミュレータで確かめる。
#
# SimCamInject/build.sh でライブラリを作り、SimCamInject/tests/ の確認用プログラムを
# シミュレータ向けにビルドして、ライブラリを読み込ませて実行する。
#   classic             expo-camera などと同じ組み方（addInput / addOutput）
#   classic --no-start  startRunning を呼ばない（expo-camera 17 のシミュレータ向けビルド）
#   manual              接続を手で張る組み方（react-native-vision-camera 5）
#   manual (multicam)   同じく AVCaptureMultiCamSession で
# どれも、落ちないこと・映像が届くこと・映像の QR が読めることを確かめる。
#
# 前提: SimulatorCameraEx.app が起動していること（映像の送り元）。
# 使い方: ./scripts/test-inject.sh [シミュレータの UDID]（省略時は起動中のもの）
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${1:-booted}"
OUT="$REPO_ROOT/build/inject-test"
SIMCAMCTL="${SIMCAMCTL:-/Applications/SimulatorCameraEx.app/Contents/MacOS/simcamctl}"

"$REPO_ROOT/SimCamInject/build.sh" "$OUT" >/dev/null 2>&1

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
for t in classic manual; do
    xcrun --sdk iphonesimulator clang -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=18.0 -fobjc-arc \
        -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework UIKit -framework QuartzCore \
        "$REPO_ROOT/SimCamInject/tests/$t.m" -o "$OUT/$t"
    codesign -f -s - "$OUT/$t" 2>/dev/null
done

"$SIMCAMCTL" set-source --qr "https://www.bluecode.co.jp" >/dev/null

failed=0
run() {
    local name="$1"; shift
    local log="$OUT/$(echo "$name" | tr ' ()' '___').log"
    if SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$OUT/SimCamInject.dylib" "$@" >"$log" 2>&1 && grep -q "PASS" "$log"; then
        printf "✓ %s\n" "$name"
    else
        printf "✗ %s（ログ: %s）\n" "$name" "$log"
        failed=1
    fi
}
run "classic"            xcrun simctl spawn "$DEVICE" "$OUT/classic"
run "classic --no-start" xcrun simctl spawn "$DEVICE" "$OUT/classic" --no-start
run "manual"             xcrun simctl spawn "$DEVICE" "$OUT/manual"
SIMCTL_CHILD_MULTICAM=1 run "manual (multicam)" xcrun simctl spawn "$DEVICE" "$OUT/manual"
exit $failed
