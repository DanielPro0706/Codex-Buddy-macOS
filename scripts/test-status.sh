#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
/bin/zsh scripts/test-mac-background-traffic.sh
/bin/zsh scripts/test-cloud-sync.sh
exec /bin/zsh scripts/test-pairing.sh
