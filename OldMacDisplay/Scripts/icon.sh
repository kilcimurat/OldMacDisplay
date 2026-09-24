#!/usr/bin/env bash
# Renders Resources/AppIcon.icns from Scripts/make-icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/Scripts/make-icon.swift" "$WORK"
mkdir -p "$ROOT/Resources"
iconutil --convert icns "$WORK/AppIcon.iconset" --output "$ROOT/Resources/AppIcon.icns"
echo "==> Wrote $ROOT/Resources/AppIcon.icns"
