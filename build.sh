#!/bin/bash
# MovieCutter を .app バンドルとしてビルドするスクリプト。
#   ./build.sh           デバッグビルド
#   ./build.sh release   リリースビルド
set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="MovieCutter"
BUILD_DIR=".build/${CONFIG}"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Swift ビルド (${CONFIG})"
swift build -c "${CONFIG}"

echo "==> .app バンドルを作成"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> アドホック署名"
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || \
    echo "   (署名をスキップしました)"

echo "==> 完了: ${APP_BUNDLE}"
echo "    起動: open ${APP_BUNDLE}"

# リリースビルドのときは /Applications にも配置する。
# （Parallels の共有アプリや Finder の「このアプリで開く」から使えるようにするため）
if [ "${CONFIG}" = "release" ]; then
    DEST="/Applications/${APP_BUNDLE}"
    echo "==> /Applications へコピー"
    rm -rf "${DEST}"
    cp -R "${APP_BUNDLE}" "${DEST}"
    # LaunchServices に書類タイプを登録し直す（動画を渡して開けるようにする）
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "${LSREGISTER}" -f "${DEST}" 2>/dev/null || true
    echo "    配置: ${DEST}"
fi
