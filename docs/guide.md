# Onramp: the full guide

A native Mac app for reviewing your AI agent's changes before a human does:
one endless, editable diff (Zed-style), inline comment threads, and a way for
any agent to read and resolve those comments.

## Install

Download the DMG from [Releases](https://github.com/timmywheels/onramp/releases/latest). It's signed and
notarized, and updates itself (**Onramp → Check for Updates…**; it also checks every 6 hours).
Then **Onramp → Install Command Line Tool…** for `onramp` in your terminal.

From source:

    ./scripts/install.sh          # builds and links ~/.local/bin/onramp

## Try it on a playground repo

    ./scripts/playground.sh    # (re)builds ~/dev/onramp-playground and opens it

A PR-shaped repo: `feat/partial-payments` is 4 commits ahead of `origin/main`,
with uncommitted edits, an untracked file and a deleted one, across TypeScript,
TSX, Rust, Go, Python, CSS and YAML. Re-run it any time to reset.

## Use

    onramp                   # from anywhere in a repo; returns right away (like `code .`)
    onramp ~/dev/other-repo  # or point it at a repo
    onramp --wait            # keep the terminal attached until the window closes

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
  `~/.config/onramp/settings.json` (**Onramp → Settings…**, ⌘,).

## Extensions

Fonts and themes come from extensions: folders with an `extension.toml`. The
built-in ones live in `app/Sources/onramp/Extensions/`; yours go in
`~/.config/onramp/extensions/<id>/` (same id replaces a built-in).

    id = "dracula"
    name = "Dracula"
    version = "0.1.0"
    api_version = 1
    themes = ["themes/dracula.json"]    # same shape as app/Sources/onramp/Extensions/one-themes/themes/*.json
    fonts = ["fonts/MyFont-Regular.ttf"] # registered for Onramp only, not system-wide

`onramp extensions` lists what loaded and why anything didn't. The
manifest already reserves what code extensions will need (`runtime =
"process"` now, `"wasm"` later, and `permissions`); those aren't supported yet.

## Review context

**Review → Context…** (⌘K, or the 📚 toolbar button): files and folders agents read before working
on your comments — review standards, architecture notes, a private checklist. Add them with the
file picker or by dropping them in. Each is *This repo* (kept in `.git/onramp/`, never
committed) or *All repos* (`~/.config/onramp/`). Folders include their text files; there are
size limits so agents get guidance, not a dump. Agents get it via the `get_review_context` MCP
tool; `onramp context` prints it.

## Connect your agent (opt-in, MCP)

Click **Connect an agent…** in the status bar. It lists Claude Code, Codex and
Cursor if installed; nothing is registered until you click **Connect** (and
**Disconnect** undoes it). Or by hand:

    # Claude Code: a plugin that bundles the MCP server + /onramp:address-comments
    claude plugin marketplace add ~/.config/onramp/integrations/claude-code
    claude plugin install onramp@onramp
    # Codex (and anything else that speaks MCP)
    codex mcp add onramp -- onramp mcp

Then ask your agent to "address my Onramp comments", or in Claude Code
type `/onramp:address-comments`. The status bar shows "● claude-code
connected" while an agent's session is live.

Comments live in `.git/onramp/comments.json` (never committed). Agents
without MCP can use the same CLI:

    onramp comments                       # open comments, with code in context
    onramp reply <id> "question"          # answer or ask
    onramp resolve <id> --note "what changed"

MCP tools: `list_comments`, `reply_to_comment`, `resolve_comment`,
`reopen_comment`, plus the `address_comments` prompt. Replies are signed with
the agent's name. The app updates live as the agent edits files and answers.

## Performance

Scrolling holds 120 fps in a 665-file review, and every keystroke is re-diffed
in about 4 ms. Measured on an M1 Max with a release build, on a synthetic
repo with 665 changed files (about 20,000 changed lines):

| What | Time |
|---|---|
| Diff a 20,000-line file | < 1 ms |
| Load a 57-file review (git + diff) | ~40 ms |
| Load a 665-file review | ~200 ms |
| Open a 2,000-line file in the editor | ~30 ms |
| Keystroke → re-diff + re-highlight | ~4 ms |
| Scroll a 665-file review | 6 ms/frame avg, p95 7–8 ms (a 120 Hz frame is 8.3 ms) |

Reproduce on any repo with uncommitted changes:

    (cd core && cargo test --release --lib fast_on_large_file -- --nocapture)
    (cd core && ONRAMP_BENCH_REPO=/path/to/repo cargo test --release --lib loads_big_review_fast -- --nocapture)
    (cd app && swift build -c release)
    ONRAMP_SELFTEST=jump      app/.build/release/onramp /path/to/repo   # scroll frame times
    ONRAMP_SELFTEST=1         app/.build/release/onramp /path/to/repo   # typing: insert + re-diff per key
    ONRAMP_SELFTEST=open-time app/.build/release/onramp /path/to/repo   # opening files in the editor

The self-tests type into a file: point them at a scratch copy, not a repo you care about.

## Layout

- `core/` Rust: git, diff, comment storage + anchoring, extension manifests (UniFFI → Swift)
- `app/` Swift/AppKit: canvas diff view, NSTextView editor, sidebar, comments, CLI, MCP
- `integrations/claude-code` Claude Code plugin (skill + bundled MCP server)
