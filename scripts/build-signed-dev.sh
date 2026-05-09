#!/usr/bin/env bash
#
# build-signed-dev.sh — build SimulatorCamera with proper Apple Development
#                       signing using the existing ASC API key. No Xcode UI
#                       account login required.
#
# Uses the bundle IDs registered in App Store Connect (com.dautov.SimulatorCamera
# and com.dautov.SimulatorCamera.Extension) under team 27EZNUVV57. The
# SYSTEM_EXTENSION_INSTALL capability is already enabled on those bundle IDs.
#
# Run this every time you want a fresh signed dev build. Re-running creates
# a new provisioning profile if the existing one is out of date.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KEY_ID="${ASC_KEY_ID:-P3XR759Z63}"
ISSUER_ID="${ASC_ISSUER_ID:-a104af48-9c8f-4749-a8a3-81ae0e8a0734}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.config/appstore-connect/AuthKey_P3XR759Z63.p8}"
TEAM_ID="${DEVELOPMENT_TEAM:-27EZNUVV57}"

if [[ ! -f "$KEY_PATH" ]]; then
    echo "ERROR: ASC API key not found at $KEY_PATH" >&2
    echo "Set ASC_KEY_PATH or place the .p8 there." >&2
    exit 1
fi

# Regenerate Xcode project from project.yml
if command -v xcodegen >/dev/null 2>&1; then
    echo "▶︎ xcodegen generate"
    xcodegen generate >/dev/null
fi

# Kill any running instance so the build doesn't hit "in use" errors
pkill -f "SimulatorCamera.app/Contents/MacOS/SimulatorCamera" 2>/dev/null || true

echo "▶︎ xcodebuild signed dev build (team $TEAM_ID)"
xcodebuild build \
    -project SimulatorCamera.xcodeproj \
    -scheme SimulatorCamera \
    -configuration Debug \
    -destination "platform=macOS" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID" \
    -authenticationKeyPath "$KEY_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    2>&1 | (xcpretty --simple || cat)

# Locate the .app
APP=$(find /Volumes/nvme/xcode/Debug /tmp -name "SimulatorCamera.app" -type d -maxdepth 3 2>/dev/null | head -1)
[[ -z "$APP" ]] && APP="$HOME/Library/Developer/Xcode/DerivedData/SimulatorCamera-*/Build/Products/Debug/SimulatorCamera.app"

echo ""
echo "▶︎ Verify signature"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" | head -5

echo ""
echo "▶︎ Verify system-extension entitlement"
codesign --display --entitlements - "$APP" 2>&1 | grep -A1 system-extension || \
    { echo "ERROR: system-extension.install entitlement missing!" >&2; exit 1; }

echo ""
echo "✅ Built signed: $APP"
echo ""
echo "Next: open '$APP' and click Activate."
echo "On first run, macOS will prompt you to Allow in System Settings → Privacy & Security."
