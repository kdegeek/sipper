#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:?helper destination required}"
SDK_PATH="${2:-$(xcrun --show-sdk-path)}"
mkdir -p "$DEST"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  helper/BH71Protocol.swift helper/BH71NativeBridge.swift -framework IOKit -o "$DEST/BH71NativeBridge"
codesign --force --sign - --options runtime "$DEST/BH71NativeBridge"
