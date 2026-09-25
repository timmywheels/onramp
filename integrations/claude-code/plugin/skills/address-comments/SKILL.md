---
description: Address the review comments the user left in Onramp on the current changes. Use when the user asks to address, fix, or respond to their Onramp (or "review") comments.
---

The user reviewed your changes in the Onramp app and left comments on specific lines.

1. Call `get_review_context` once: files the user chose as review standards and background. Follow them.
2. Call the `list_comments` tool (Onramp MCP server, named `onramp`) to get every open comment with the code it refers to.
3. For each open comment, call `claim_comment` with its id first. If it's claimed by another agent, skip it: someone else is on it. Then fix the code.
4. After fixing one, call `resolve_comment` with its id and a one-line note on what you changed.
5. If a comment needs a decision from the user, call `reply_to_comment` with your question instead of resolving it. If you can't do one, call `release_comment` so another agent can.
6. When done, call `list_comments` again to confirm nothing is left open, and summarize what you changed and what's waiting on the user.

$ARGUMENTS
