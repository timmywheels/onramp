#!/usr/bin/env bash
# Builds pairprogram (release) and links it into ~/.local/bin so you and your
# agents can run `pairprogram` from any repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-core.sh"
(cd "$ROOT/app" && swift build -c release)
# Claude Code plugin (/pairprogram:address-comments + MCP server), installed from here by the app's Connect button.
mkdir -p "$HOME/.config/pairprogram/integrations"
rsync -a --delete "$ROOT/integrations/claude-code/" "$HOME/.config/pairprogram/integrations/claude-code/"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/app/.build/release/pairprogram" "$HOME/.local/bin/pairprogram"
echo "installed: ~/.local/bin/pairprogram"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to your PATH, e.g. echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
