#!/bin/sh
# Собирает неподписанный OpenLuch-<версия>.ipa для установки через AltStore / Sideloadly.
# Запуск из корня проекта: tools/build-ipa.sh
#
# Зачем без подписи: AltStore и Sideloadly сами подписывают приложение Apple ID того, кто
# его ставит, — наша подпись им не нужна (и бесплатной подписью мы всё равно не можем
# подписать приложение для чужого iPhone).
#
# Что такое .ipa: обычный zip-архив, внутри которого папка Payload с OpenLuch.app.

set -e

cd "$(dirname "$0")/.."

BUILD_DIR="build/ipa"
rm -rf "$BUILD_DIR"

# Release-сборка для настоящего iPhone (не для симулятора), подпись выключена.
echo "Сборка Release для iPhone (1–3 минуты)…"
xcodebuild build \
    -project OpenLuch.xcodeproj \
    -scheme OpenLuch \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    -quiet

APP="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/OpenLuch.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Info.plist")

# Упаковка: Payload/OpenLuch.app → zip с расширением .ipa.
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
IPA="build/OpenLuch-$VERSION.ipa"
rm -f "$IPA"
(cd "$BUILD_DIR" && zip -qry "../OpenLuch-$VERSION.ipa" Payload)

echo "Готово: $IPA (версия $VERSION, сборка $BUILD, $(du -h "$IPA" | cut -f1))"
