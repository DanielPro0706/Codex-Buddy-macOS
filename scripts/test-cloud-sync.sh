#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
test_output=$(mktemp -d /tmp/codexbuddy-cloud-sync-tests.XXXXXX)
cleanup() {
  local cleanup_exit_code=$?
  trap - EXIT
  # Retain recoverable intermediates without requiring Finder or an active GUI.
  if [[ -d "$test_output" ]]; then
    local trash_destination="$HOME/.Trash/${test_output:t}"
    if mkdir -p "$HOME/.Trash" && mv "$test_output" "$trash_destination"; then
      print -r -- "Test intermediates moved to Trash: $trash_destination"
    else
      print -u2 -r -- "Could not move test intermediates to Trash; retained at $test_output"
    fi
  fi
  return "$cleanup_exit_code"
}
trap cleanup EXIT

xcrun swiftc -module-cache-path "$test_output/module-cache" \
  Shared/CodexStatusModels.swift Shared/CodexStatusCache.swift \
  Shared/CodexCloudSync.swift \
  Tests/CloudSyncCancellationTests.swift -o "$test_output/cloud-sync-tests"
"$test_output/cloud-sync-tests"
