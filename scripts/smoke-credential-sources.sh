#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
ARCH="$(uname -m)"

SMOKE_BUILD_DIR="${ROOT_DIR}/.build/smoke"
mkdir -p "${SMOKE_BUILD_DIR}"
SMOKE_BIN="${SMOKE_BUILD_DIR}/ProviderLimitsHostSmoke"

swiftc \
    -O \
    -swift-version 6 \
    -parse-as-library \
    -target "${ARCH}-apple-macosx14.0" \
    -I "${BUILD_DIR}/Modules" \
    "${BUILD_DIR}"/ProviderLimitsCore.build/*.o \
    App/MenuBarContentView.swift \
    App/SettingsView.swift \
    App/AboutSettingsSection.swift \
    App/MenuBarState.swift \
    App/MenuBarController.swift \
    Tests/ProviderLimitsHostSmoke/*.swift \
    -o "${SMOKE_BIN}"

cleanup() {
    rm -rf "${SMOKE_BUILD_DIR}/tmp" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"${SMOKE_BIN}" "$@"
