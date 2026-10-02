#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
test_output=$(mktemp -d /tmp/codexbuddy-status-tests.XXXXXX)
trap 'rm -rf "$test_output"' EXIT
xcrun swiftc -module-cache-path "$test_output/module-cache" \
  'Shared/CodexStatusModels.swift' 'Codex Buddy Mac/LocalCodexStatusReader.swift' \
  Tests/StatusRegressionTests.swift -o "$test_output/status-tests"
"$test_output/status-tests"
# Compile the production lifecycle delegate with harmless UI/service substitutes.
awk '/^@MainActor$/{mark=$0; next} /^final class MainWindowDockVisibilityController/{exit} {if (mark != "") {print mark; mark=""}; print}' \
  'Codex Buddy Mac/MacMenuBarController.swift' > "$test_output/MacLifecycleDelegate.swift"
xcrun swiftc -default-isolation MainActor -module-cache-path "$test_output/module-cache" \
  'Shared/CodexStatusModels.swift' 'Codex Buddy Mac/MacStatusStore.swift' \
  "$test_output/MacLifecycleDelegate.swift" Tests/MacRefreshTestSupport.swift \
  Tests/MacRefreshRegressionTests.swift -o "$test_output/refresh-tests"
"$test_output/refresh-tests"
