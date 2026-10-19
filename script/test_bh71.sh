#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bh71
xcrun swiftc -swift-version 5 Sipper/Headset/BH71CallControl.swift script/BH71CallControlTests.swift -o build/bh71/call-control-tests
build/bh71/call-control-tests
xcrun swiftc -swift-version 5 -D SIPPER_BH71_TEST Sipper/BuildIdentity.swift Sipper/Store/PasswordStore.swift script/PasswordIsolationTests.swift -o build/bh71/password-isolation-tests
build/bh71/password-isolation-tests
xcrun swiftc -swift-version 5 helper/BH71Protocol.swift script/BH71ProtocolTests.swift -o build/bh71/protocol-tests
build/bh71/protocol-tests
