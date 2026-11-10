#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
/bin/zsh scripts/test-mac-background-traffic.sh
configuration_output=$(mktemp -d /tmp/codexbuddy-cloudspace-tests.XXXXXX)
xcrun swiftc -module-cache-path "$configuration_output/module-cache" \
  BuddyCloudSpace/CloudSpaceConfiguration.swift Tests/CloudSpaceConfigurationTests.swift \
  -o "$configuration_output/configuration-tests"
"$configuration_output/configuration-tests"
print -r -- "Retained CloudSpace artifacts: $configuration_output"
if [[ -f 'Codex Buddy New/MacUpdateNotice.swift' ]]; then
  notice_output=$(mktemp -d /tmp/codexbuddy-notice-tests.XXXXXX)
  xcrun swiftc -default-isolation MainActor -module-cache-path "$notice_output/module-cache" \
    'Codex Buddy New/MacUpdateNotice.swift' Tests/MacUpdateNoticeRegressionTests.swift \
    -o "$notice_output/notice-tests"
  "$notice_output/notice-tests"
  print -r -- "Retained notice artifacts: $notice_output"
fi
