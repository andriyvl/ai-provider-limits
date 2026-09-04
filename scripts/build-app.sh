#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "Building Swift Package..."
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
ARCH="$(uname -m)"

APP_NAME="AI Limits"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

sed -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.andriyvl.ai-provider-limits/g' \
    -e 's/\$(PRODUCT_NAME)/AI Limits/g' \
    -e 's/\$(EXECUTABLE_NAME)/AI Limits/g' \
    -e 's/\$(DEVELOPMENT_LANGUAGE)/en/g' \
    "App/Info.plist" > "${CONTENTS_DIR}/Info.plist"

CORE_BUNDLE="${BUILD_DIR}/ProviderLimitsCore_ProviderLimitsCore.bundle"
if [[ -d "${CORE_BUNDLE}" ]]; then
    cp -R "${CORE_BUNDLE}" "${RESOURCES_DIR}/"
fi
if [[ -f "${ROOT_DIR}/App/Resources/AppIcon.icns" ]]; then
    cp "${ROOT_DIR}/App/Resources/AppIcon.icns" "${RESOURCES_DIR}/"
fi
cp "${ROOT_DIR}/App/Resources/MenuBarIcon.png" "${ROOT_DIR}/App/Resources/MenuBarIcon@2x.png" "${RESOURCES_DIR}/"
cp "${ROOT_DIR}/LICENSE" "${ROOT_DIR}/NOTICE" "${RESOURCES_DIR}/"

echo "Compiling App Binary..."
swiftc \
    -O \
    -parse-as-library \
    -target "${ARCH}-apple-macosx14.0" \
    -I "${BUILD_DIR}/Modules" \
    "${BUILD_DIR}"/ProviderLimitsCore.build/*.o \
    App/MenuBarHostApp.swift \
    App/MenuBarContentView.swift \
    -o "${MACOS_DIR}/AI Limits"

codesign --force --deep --sign - --entitlements "App/ProviderLimits.entitlements" "${APP_DIR}" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "${APP_DIR}" 2>/dev/null || true
echo "Build successful: ${APP_DIR}"
