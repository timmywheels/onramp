#!/usr/bin/env python3
"""Builds a big, made-up repo for demos: ~600 changed files across TypeScript,
Rust, Python, Go and Swift, on a branch `feat/big-refactor` against `main`.
Everything is generated (seeded, so it's the same every time); no real code.

    ./scripts/demo-repo.py [dir]    # default ~/dev/onramp-demo
"""
import os
import random
import re
import shutil
import subprocess
import sys

DIR = os.path.abspath(os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/dev/onramp-demo"))
if "demo" not in os.path.basename(DIR):
    sys.exit(f"refusing to reset {DIR} (name must contain 'demo')")

rng = random.Random(42)
NOUNS = ["invoice", "payment", "account", "session", "order", "ledger", "refund", "customer", "plan", "coupon",
         "report", "webhook", "export", "receipt", "balance", "member", "schedule", "booking", "tax", "payout"]
VERBS = ["load", "save", "sync", "apply", "build", "check", "render", "parse", "merge", "fetch", "cancel", "retry"]
DIRS = ["api/src", "billing/src", "worker/src", "web/src/components", "web/src/hooks", "core/src", "jobs", "ios/Sources"]


def plural(n):
    return n[:-1] + "ies" if n.endswith("y") else n + "es" if n.endswith(("x", "s", "ch")) else n + "s"


def ident(camel=True):
    v, n = rng.choice(VERBS), rng.choice(NOUNS)
    return v + n.capitalize() if camel else f"{v}_{n}"


def ts_fn():
    name, n = ident(), rng.choice(NOUNS)
    return [f"export async function {name}(id: string, opts: {{ limit?: number }} = {{}}): Promise<{n.capitalize()}[]> {{",
            f"  const rows = await db.{plural(n)}.findMany({{ where: {{ accountId: id }}, take: opts.limit ?? {rng.randint(10, 500)} }});",
            f"  if (rows.length === 0) return [];",
            f"  return rows.map((r) => ({{ ...r, total: r.amount * {rng.randint(1, 9)} }}));",
            "}", ""]


def rs_fn():
    name, n = ident(False), rng.choice(NOUNS)
    return [f"pub fn {name}(items: &[{n.capitalize()}], limit: usize) -> Result<Vec<u64>, Error> {{",
            f"    let mut out = Vec::with_capacity(limit.min({rng.randint(16, 256)}));",
            f"    for item in items.iter().take(limit) {{",
            f"        out.push(item.amount.checked_mul({rng.randint(2, 99)}).ok_or(Error::Overflow)?);",
            "    }", "    Ok(out)", "}", ""]


def py_fn():
    name, n = ident(False), rng.choice(NOUNS)
    return [f"def {name}(conn, account_id: str, limit: int = {rng.randint(10, 500)}) -> list[dict]:",
            f'    """Return the {plural(n)} for an account, newest first."""',
            f"    rows = conn.query(\"select * from {plural(n)} where account_id = %s limit %s\", (account_id, limit))",
            f"    return [dict(r, total=r['amount'] * {rng.randint(1, 9)}) for r in rows]", "", ""]


def go_fn():
    name, n = ident(), rng.choice(NOUNS)
    name = name[0].upper() + name[1:]
    return [f"func {name}(ctx context.Context, id string) ([]{n.capitalize()}, error) {{",
            f"\trows, err := store.Query(ctx, \"{plural(n)}\", id, {rng.randint(10, 500)})",
            "\tif err != nil {", f"\t\treturn nil, fmt.Errorf(\"{name}: %w\", err)", "\t}", "\treturn rows, nil", "}", ""]


def swift_fn():
    name, n = ident(), rng.choice(NOUNS)
    return [f"func {name}(_ id: String, limit: Int = {rng.randint(10, 500)}) async throws -> [{n.capitalize()}] {{",
            f"    let rows = try await api.{plural(n)}(account: id, limit: limit)",
            f"    return rows.filter {{ $0.amount > {rng.randint(0, 99)} }}", "}", ""]


LANGS = [("ts", ts_fn, ['import { db } from "../db";', ""]), ("rs", rs_fn, ["use crate::{Error, model::*};", ""]),
         ("py", py_fn, ['"""Generated demo module."""', ""]), ("go", go_fn, ["package app", "", 'import ("context"; "fmt")', ""]),
         ("swift", swift_fn, ["import Foundation", ""])]


def module(lang, fns):
    ext, gen, head = lang
    lines = list(head)
    for _ in range(fns):
        lines += gen()
    return lines


def change(lines, lang):
    """Edit a module the way a refactor would, a whole function at a time:
    rename or retune lines inside some, add a few, drop one."""
    blocks, cur = [], []
    for line in lines:  # functions are separated by blank lines
        cur.append(line)
        if not line.strip():
            blocks.append(cur)
            cur = []
    if cur:
        blocks.append(cur)
    _, gen, header = lang
    n = sum(1 for line in header if not line.strip())  # the header's own blocks (Go has two)
    head, fns = blocks[:n], blocks[n:]
    for fn in rng.sample(fns, min(len(fns), rng.randint(2, 6))):  # renames, and numbers that moved
        for i, line in enumerate(fn):
            if rng.random() < 0.5:
                new = line.replace("limit", "maxItems").replace("amount", "amountCents")
                fn[i] = new if new != line else re.sub(r"\b\d+\b", lambda m: str(int(m.group()) * 2), line, count=1)
    for _ in range(rng.randint(1, 3)):  # new functions
        fns.insert(rng.randint(0, len(fns)), gen())
    if len(fns) > 4:  # and one goes away
        del fns[rng.randrange(len(fns))]
    return [line for block in head + fns for line in block]


def git(*args):
    subprocess.run(["git", "-C", DIR, *args], check=True, stdout=subprocess.DEVNULL)


def write(path, lines):
    full = os.path.join(DIR, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write("\n".join(lines) + "\n")


shutil.rmtree(DIR, ignore_errors=True)
os.makedirs(DIR)
git("init", "-q", "-b", "main")
git("config", "user.name", "Demo")
git("config", "user.email", "demo@example.com")

files = {}
for i in range(640):
    lang = rng.choice(LANGS)
    path = f"{rng.choice(DIRS)}/{rng.choice(NOUNS)}_{i:03d}.{lang[0]}"
    files[path] = (lang, module(lang, rng.randint(6, 22)))
    write(path, files[path][1])
write("README.md", ["# Demo", "", "A generated repo for trying Onramp on a big diff. Nothing here is real."])
git("add", "-A")
git("commit", "-q", "-m", "Initial import")

git("checkout", "-q", "-b", "feat/big-refactor")
paths = sorted(files)
for path in paths[:560]:  # most files change
    lang, lines = files[path]
    write(path, change(lines, lang))
for path in paths[560:580]:  # some go away
    os.remove(os.path.join(DIR, path))
for i in range(40):  # and some are new
    lang = rng.choice(LANGS)
    write(f"{rng.choice(DIRS)}/new_{rng.choice(NOUNS)}_{i:02d}.{lang[0]}", module(lang, rng.randint(3, 8)))
git("add", "-A")
git("commit", "-q", "-m", "Big refactor: amounts in cents, bounded queries")

stat = subprocess.run(["git", "-C", DIR, "diff", "--shortstat", "main"], capture_output=True, text=True).stdout.strip()
print(f"{DIR}: feat/big-refactor vs main: {stat}")
