#!/usr/bin/env bash
# Records-ready demo: a big made-up diff (620 files, ~18k changed lines, nothing
# real) opened in Onramp, which then scrolls through it on its own.
#   ./scripts/demo.sh            # repo in ~/dev/onramp-demo
#   ./scripts/demo.sh <dir>      # somewhere else (name must contain "demo")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$HOME/dev/onramp-demo}"
"$ROOT/scripts/demo-repo.py" "$DIR"
(cd "$ROOT/app" && swift build -c release -q)
echo
echo "Onramp opens at 1440×900, waits 4 s, then tours the diff (~20 s)."
echo "To record just its window: ⌘⇧5 → Record Selected Window → click Onramp."
ONRAMP_DEMO=1 ONRAMP_DETACHED=1 "$ROOT/app/.build/release/onramp" "$DIR"
