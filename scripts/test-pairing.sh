#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
pairing_output=$(mktemp -d /tmp/codexbuddy-pairing-tests.XXXXXX)
xcrun swiftc -swift-version 6 -default-isolation MainActor \
  -module-cache-path "$pairing_output/module-cache" \
  Shared/CodexStatusModels.swift \
  BuddySnapShared/PairingInfo.swift BuddySnapShared/RelayConfiguration.swift \
  BuddySnapShared/RelayChannel.swift BuddySnapShared/SecureChannel.swift \
  BuddySnapShared/WireMessage.swift BuddyCore/BuddyPairingPayload.swift \
  Tests/BuddyPairingPayloadTests.swift -o "$pairing_output/pairing-tests"
"$pairing_output/pairing-tests"
print -r -- "Retained pairing test artifacts: $pairing_output"
