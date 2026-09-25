#!/usr/bin/env bash
# Builds Onramp (release) and links it into ~/.local/bin so you and your
# agents can run `onramp` (or `ramp`) from any repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-core.sh"
(cd "$ROOT/app" && swift build -c release)
# Claude Code plugin (/onramp:address-comments + MCP server), installed from here by the app's Connect button.
mkdir -p "$HOME/.config/onramp/integrations"
rsync -a --delete "$ROOT/integrations/claude-code/" "$HOME/.config/onramp/integrations/claude-code/"
mkdir -p "$HOME/.local/bin"
for name in onramp ramp; do
  ln -sf "$ROOT/app/.build/release/onramp" "$HOME/.local/bin/$name"
done
echo "installed: ~/.local/bin/onramp (and ramp)"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to your PATH, e.g. echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
