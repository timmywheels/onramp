# PairProgram

A native Mac app for reviewing your AI agent's changes before a human does:
one endless, editable diff (Zed-style), inline comment threads, and a way for
any agent to read and resolve those comments.

## Install

    ./scripts/install.sh          # builds and links ~/.local/bin/pair

## Try it on a playground repo

    ./scripts/playground.sh    # (re)builds ~/dev/pairprogram-playground and opens it

A PR-shaped repo: `feat/partial-payments` is 4 commits ahead of `origin/main`,
with uncommitted edits, an untracked file and a deleted one, across TypeScript,
TSX, Rust, Go, Python, CSS and YAML. Re-run it any time to reset.

## Use

    pair                   # from anywhere in a repo; returns right away (like `code .`)
    pair ~/dev/other-repo  # or point it at a repo
    pair --wait            # keep the terminal attached until the window closes

- Hover a line and click **+** (or click its line number) to comment. **Comment** posts it now;
  **Start a review** holds it (and later ones) as *Pending*, like GitHub.
- **Finish review (N)** in the status bar: add a summary, pick Comment / Approve / Request changes,
  and choose who to send it to. Submitting publishes the pending comments and can start
  Claude Code (`claude -p`) or Codex (`codex exec`) in the repo to address them; their fixes and
  replies show up live. Pending comments are invisible to agents until you submit.
- **Toolbar, left:** switch project or worktree (this repo's worktrees, recent projects, ⌘O to open a folder).
- **Toolbar, right — what to review:** *All changes on this branch* (committed or not, against where it left
  its base branch — `origin/HEAD`, else main/master, or pick one under *Compare Against*), *Uncommitted
  changes*, or one of the branch's commits (read-only). Saved per repo; agents see the same set.
- **Viewed** checkboxes fold files as you go; the status bar shows progress. ⌥⌘← / ⌥⌘→ collapse/expand all.
- Click any line to edit it in place. ⌘S saves all files.
- Click a file header to fold it; click "⋯ unchanged lines" to show more context.
- ⌃⌘S toggles the file tree, ⌘+/⌘− change the font, ⇧⌘R shows resolved comments.
- **View → Font / Font Ligatures / Theme / Appearance.** The default font is
  [Lilex](https://github.com/mishamyrt/Lilex) (bundled, OFL). Everything is also in
  `~/.config/pairprogram/settings.json` (**PairProgram → Settings…**, ⌘,).

## Extensions

Fonts and themes come from extensions: folders with an `extension.toml`. The
built-in ones live in `app/Sources/pairprogram/Extensions/`; yours go in
`~/.config/pairprogram/extensions/<id>/` (same id replaces a built-in).

    id = "dracula"
    name = "Dracula"
    version = "0.1.0"
    api_version = 1
    themes = ["themes/dracula.json"]    # same shape as app/Sources/pairprogram/Extensions/one-themes/themes/*.json
    fonts = ["fonts/MyFont-Regular.ttf"] # registered for PairProgram only, not system-wide

`pair extensions` lists what loaded and why anything didn't. The
manifest already reserves what code extensions will need (`runtime =
"process"` now, `"wasm"` later, and `permissions`); those aren't supported yet.

## Review context

**Review → Context…** (⌘K, or the 📚 toolbar button): files and folders agents read before working
on your comments — review standards, architecture notes, a private checklist. Add them with the
file picker or by dropping them in. Each is *This repo* (kept in `.git/pairprogram/`, never
committed) or *All repos* (`~/.config/pairprogram/`). Folders include their text files; there are
size limits so agents get guidance, not a dump. Agents get it via the `get_review_context` MCP
tool; `pair context` prints it.

## Connect your agent (opt-in, MCP)

Click **Connect an agent…** in the status bar. It lists Claude Code, Codex and
Cursor if installed; nothing is registered until you click **Connect** (and
**Disconnect** undoes it). Or by hand:

    # Claude Code: a plugin that bundles the MCP server + /pairprogram:address-comments
    claude plugin marketplace add ~/.config/pairprogram/integrations/claude-code
    claude plugin install pairprogram@pairprogram
    # Codex (and anything else that speaks MCP)
    codex mcp add pairprogram -- pair mcp

Then ask your agent to "address my PairProgram comments", or in Claude Code
type `/pairprogram:address-comments`. The status bar shows "● claude-code
connected" while an agent's session is live.

Comments live in `.git/pairprogram/comments.json` (never committed). Agents
without MCP can use the same CLI:

    pair comments                       # open comments, with code in context
    pair reply <id> "question"          # answer or ask
    pair resolve <id> --note "what changed"

MCP tools: `list_comments`, `reply_to_comment`, `resolve_comment`,
`reopen_comment`, plus the `address_comments` prompt. Replies are signed with
the agent's name. The app updates live as the agent edits files and answers.

## Layout

- `core/` Rust: git, diff, comment storage + anchoring, extension manifests (UniFFI → Swift)
- `app/` Swift/AppKit: canvas diff view, NSTextView editor, sidebar, comments, CLI, MCP
- `integrations/claude-code` Claude Code plugin (skill + bundled MCP server)
