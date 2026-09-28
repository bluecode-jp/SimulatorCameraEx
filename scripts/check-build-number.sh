#!/usr/bin/env bash
#
# check-build-number.sh — リリース前に、ビルド番号が過去のリリースより大きいか確かめる。
#
# project.yml の CURRENT_PROJECT_VERSION を、リリースタグ（vX.Y.Z）時点の値と比べる。
# 今回のバージョンのタグ（v<MARKETING_VERSION>）は、作り直しのこともあるので比較から外す。
#
# ビルド番号が同じだと、配布先の Mac で拡張が入れ替わらない。アプリは「同梱の拡張が
# 入っている」と判断するため、Deactivate が OSSystemExtensionErrorDomain error 4 で失敗する
# （1.0.1 をビルド番号 6 のまま出して起きた）。
#
# 環境変数:
#   SKIP_BUILD_NUMBER_CHECK=1   チェックを飛ばす（配布しない確認用のビルドだけに使う）
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "${SKIP_BUILD_NUMBER_CHECK:-}" == "1" ]]; then
    echo "⚠︎ ビルド番号のチェックを飛ばしました（SKIP_BUILD_NUMBER_CHECK=1）" >&2
    exit 0
fi

# project.yml（またはタグ時点の project.yml）から設定値を1つ取り出す
read_setting() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" | head -1; }

VERSION="$(read_setting MARKETING_VERSION < project.yml)"
BUILD="$(read_setting CURRENT_PROJECT_VERSION < project.yml)"

if [[ ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: project.yml の CURRENT_PROJECT_VERSION は正の整数にしてください（今: \"${BUILD}\"）" >&2
    exit 1
fi

# 浅い clone ではタグが無く、比べる相手が見つからないまま通ってしまう
if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
    echo "ERROR: 浅い clone ではリリースタグを参照できません。'git fetch --tags --unshallow' を実行してください" >&2
    exit 1
fi

MAX_BUILD=0
MAX_TAG=""
while IFS= read -r tag; do
    [[ "$tag" == "v$VERSION" ]] && continue
    tag_build="$(git show "$tag:project.yml" 2>/dev/null | read_setting CURRENT_PROJECT_VERSION || true)"
    [[ "$tag_build" =~ ^[0-9]+$ ]] || continue
    if (( tag_build >= MAX_BUILD )); then
        MAX_BUILD=$tag_build
        MAX_TAG=$tag
    fi
done < <(git tag --list 'v*' --sort=v:refname)

if [[ -z "$MAX_TAG" ]]; then
    echo "✓ ビルド番号 ${BUILD}（比べるリリースタグがありません）"
    exit 0
fi

if (( BUILD <= MAX_BUILD )); then
    echo "ERROR: ビルド番号 ${BUILD} が、リリース済みの ${MAX_TAG}（ビルド番号 ${MAX_BUILD}）より大きくありません" >&2
    echo "       project.yml の CURRENT_PROJECT_VERSION を $((MAX_BUILD + 1)) にしてください（RELEASING.md の手順1）" >&2
    exit 1
fi

echo "✓ ビルド番号 ${BUILD}（リリース済みの最大は ${MAX_TAG} の ${MAX_BUILD}）"
