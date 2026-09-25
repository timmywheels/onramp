---
description: Address the review comments the user left in pairprogram on the current changes. Use when the user asks to address, fix, or respond to their pairprogram (or "review") comments.
---

The user reviewed your changes in the pairprogram app and left comments on specific lines.

1. Call the `list_comments` tool (pairprogram MCP server) to get every open comment with the code it refers to.
2. For each open comment, fix the code.
3. After fixing one, call `resolve_comment` with its id and a one-line note on what you changed.
4. If a comment needs a decision from the user, call `reply_to_comment` with your question instead of resolving it.
5. When done, call `list_comments` again to confirm nothing is left open, and summarize what you changed and what's waiting on the user.

$ARGUMENTS
