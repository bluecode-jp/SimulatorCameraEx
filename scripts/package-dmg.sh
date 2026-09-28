#!/usr/bin/env bash
#
# package-dmg.sh — 公証済みの SimulatorCameraEx.app から配布用ファイルを作る。
#
# 使い方:
#   ./scripts/package-dmg.sh [公証済みの .app]
#
# .app を省略すると、Organizer の最新のアーカイブで公証済みのもの
# （<archive>/Submissions/<UUID>/SimulatorCameraEx.app）を使う。
#
# 作るもの:
#   dist/SimulatorCameraEx-<VERSION>.dmg   アプリと /Applications へのリンク
#   dist/SimulatorCameraEx-<VERSION>.zip
#   dist/SimulatorCameraEx-<VERSION>.sha256
#
# DMG 自体は署名しない（手元に Developer ID 証明書がないため）。中のアプリは
# 公証チケットが付いているので、ダウンロードした Mac でもそのまま開ける。
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

APP="${1:-}"
if [[ -z "$APP" ]]; then
    APP="$(ls -td "$HOME"/Library/Developer/Xcode/Archives/*/SimulatorCameraEx*.xcarchive/Submissions/*/SimulatorCameraEx.app 2>/dev/null | head -1 || true)"
fi
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "ERROR: 公証済みの SimulatorCameraEx.app が見つかりません。引数で指定してください。" >&2
    exit 1
fi
APP="${APP%/}"
echo "▶︎ $APP"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

# ── 検証: Developer ID 署名・公証済みであること ──────────────────────────────

check_developer_id() {
    # grep -q が早く抜けると pipefail で codesign 側が失敗扱いになるので、先に受ける。
    local info
    info="$(codesign -dvv "$1" 2>&1 || true)"
    [[ "$info" == *$'\nAuthority=Developer ID Application'* ]] \
        || { echo "ERROR: Developer ID で署名されていません: $1" >&2; exit 1; }
}
check_developer_id "$APP"
check_developer_id "$APP/Contents/MacOS/simcamctl"
for f in "$APP"/Contents/Library/SystemExtensions/*.systemextension "$APP"/Contents/Resources/SimCamInject/*.dylib; do
    check_developer_id "$f"
done
codesign --verify --deep --strict "$APP" \
    || { echo "ERROR: 署名が壊れています" >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null \
    || { echo "ERROR: 公証チケットが付いていません（Organizer で公証が終わっているか確認）" >&2; exit 1; }
spctl -a -t exec "$APP" \
    || { echo "ERROR: Gatekeeper に拒否されました" >&2; exit 1; }
echo "✓ Developer ID 署名・公証済み"

# ── 作成 ────────────────────────────────────────────────────────────────────

mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/SimulatorCameraEx.app"
ln -s /Applications "$STAGE/Applications"

DMG_OUT="$DIST_DIR/SimulatorCameraEx-$VERSION.dmg"
ZIP_OUT="$DIST_DIR/SimulatorCameraEx-$VERSION.zip"
rm -f "$DMG_OUT" "$ZIP_OUT"

echo "▶︎ DMG"
hdiutil create -volname "SimulatorCameraEx $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG_OUT" >/dev/null 2>&1
echo "▶︎ ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/SimulatorCameraEx.app" "$ZIP_OUT"

(
    cd "$DIST_DIR"
    shasum -a 256 "SimulatorCameraEx-$VERSION.dmg" "SimulatorCameraEx-$VERSION.zip" \
        > "SimulatorCameraEx-$VERSION.sha256"
)

echo "✓ 完成"
ls -la "$DMG_OUT" "$ZIP_OUT" "$DIST_DIR/SimulatorCameraEx-$VERSION.sha256"
