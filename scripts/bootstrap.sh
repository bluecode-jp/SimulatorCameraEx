#!/usr/bin/env bash
# Bootstrap a fresh checkout: generate the Xcode project and build.
#
# Note: this project is NOT a Swift Package. System extensions cannot be
# built by SwiftPM, so the project is Xcode-managed via project.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ Swift version"
swift --version

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✖ xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "▶ Generating SimulatorCamera.xcodeproj from project.yml"
xcodegen generate

echo "▶ Building (Debug)"
xcodebuild -project SimulatorCamera.xcodeproj \
           -scheme SimulatorCamera \
           -configuration Debug \
           build

if command -v swiftlint >/dev/null 2>&1; then
  echo "▶ SwiftLint"
  swiftlint --strict || true
fi

echo "✅ Bootstrap complete."
echo "   Next: open SimulatorCamera.xcodeproj"
echo "   To activate the extension locally: systemextensionsctl developer on"
