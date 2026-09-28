#!/usr/bin/env bash
#
# archive-release.sh — Release の .xcarchive を作り、Xcode の Organizer で開く。
#
# 署名と公証は Organizer の Distribute App → Direct Distribution で行う
# （クラウド管理の Developer ID 証明書を使うため、手元に証明書は要らない）。
# 公証が終わったら scripts/package-dmg.sh で DMG を作る。手順は RELEASING.md。
#
# 環境変数:
#   APPLE_TEAM_ID   チーム ID（既定: C5TUJ8526Z）
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TEAM_ID="${APPLE_TEAM_ID:-C5TUJ8526Z}"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)"
BUILD="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)"
WORK_DIR="$REPO_ROOT/build/release"
ARCHIVES_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ARCHIVE_PATH="$ARCHIVES_DIR/SimulatorCameraEx $VERSION ($BUILD) $(date +%H.%M.%S).xcarchive"

# ビルド番号が過去のリリースより大きいこと（同じだと配布先で拡張が入れ替わらない）
"$REPO_ROOT/scripts/check-build-number.sh"

if command -v xcodegen >/dev/null 2>&1; then
    echo "▶︎ xcodegen generate"
    xcodegen generate
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$ARCHIVES_DIR"

echo "▶︎ Archiving SimulatorCameraEx $VERSION ($BUILD)"
xcodebuild \
    -project SimulatorCamera.xcodeproj \
    -scheme SimulatorCamera \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$WORK_DIR/dd" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive 2>&1 | (xcpretty --simple 2>/dev/null || grep -E "error:|warning: .*sign|\*\* ARCHIVE")

# アプリのアーカイブと認識されていないと、Organizer に配布方法が出ない。
if ! /usr/libexec/PlistBuddy -c "Print :ApplicationProperties:ApplicationPath" "$ARCHIVE_PATH/Info.plist" >/dev/null 2>&1; then
    echo "ERROR: macOS App Archive になっていません（アプリ以外の成果物が含まれている可能性）" >&2
    exit 1
fi

echo "✓ $ARCHIVE_PATH"
open "$ARCHIVE_PATH"
echo "Organizer で Distribute App → Direct Distribution を実行してください。"
