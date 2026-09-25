#!/usr/bin/env bash
# Creates a throwaway git repo with a realistic uncommitted diff and opens
# onramp on it. Re-run any time to reset it.
#   ./scripts/demo.sh            # repo in $TMPDIR/onramp-demo
#   ./scripts/demo.sh <dir>      # somewhere else
set -euo pipefail
DIR="${1:-${TMPDIR:-/tmp}/onramp-demo}"
rm -rf "$DIR" && mkdir -p "$DIR" && cd "$DIR"
git init -q
git config user.name "${GIT_AUTHOR_NAME:-$(git config --global user.name || echo you)}"
git config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email || echo you@example.com)}"

mkdir -p src/api src/lib tests
cat > src/api/todos.ts <<'EOF'
import { db } from "../lib/db";
import { Todo } from "../lib/types";

export async function listTodos(userId: string): Promise<Todo[]> {
  const rows = await db.query("select * from todos where user_id = $1", [userId]);
  return rows.map(toTodo);
}

export async function createTodo(userId: string, title: string): Promise<Todo> {
  const row = await db.one(
    "insert into todos (user_id, title) values ($1, $2) returning *",
    [userId, title],
  );
  return toTodo(row);
}

export async function completeTodo(id: string): Promise<void> {
  await db.query("update todos set done = true where id = $1", [id]);
}

function toTodo(row: any): Todo {
  return { id: row.id, title: row.title, done: row.done };
}
EOF
cat > src/lib/types.ts <<'EOF'
export interface Todo {
  id: string;
  title: string;
  done: boolean;
}
EOF
cat > src/lib/db.ts <<'EOF'
import { Pool } from "pg";

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

export const db = {
  async query(sql: string, params: unknown[] = []) {
    const res = await pool.query(sql, params);
    return res.rows;
  },
  async one(sql: string, params: unknown[] = []) {
    const rows = await this.query(sql, params);
    return rows[0];
  },
};
EOF
cat > src/lib/legacy-cache.ts <<'EOF'
// Old in-memory cache. Nothing reads from it anymore.
const cache = new Map<string, unknown>();

export function get(key: string) {
  return cache.get(key);
}

export function set(key: string, value: unknown) {
  cache.set(key, value);
}
EOF
cat > tests/todos.test.ts <<'EOF'
import { createTodo, listTodos } from "../src/api/todos";

test("creates and lists todos", async () => {
  const todo = await createTodo("u1", "write tests");
  const todos = await listTodos("u1");
  expect(todos).toContainEqual(todo);
});
EOF
cat > README.md <<'EOF'
# todo-api

A tiny todo API used to try onramp.
EOF
git add -A && git commit -qm "initial todo api"

# ---- the "agent's" uncommitted changes ----
cat > src/api/todos.ts <<'EOF'
import { db } from "../lib/db";
import { Todo, TodoPatch } from "../lib/types";

const MAX_TITLE = 200;

export async function listTodos(userId: string, opts: { includeDone?: boolean } = {}): Promise<Todo[]> {
  const rows = opts.includeDone
    ? await db.query("select * from todos where user_id = $1 order by created_at", [userId])
    : await db.query("select * from todos where user_id = $1 and done = false order by created_at", [userId]);
  return rows.map(toTodo);
}

export async function createTodo(userId: string, title: string): Promise<Todo> {
  if (title.trim().length === 0) throw new Error("title is required");
  if (title.length > MAX_TITLE) throw new Error(`title is longer than ${MAX_TITLE} characters`);
  const row = await db.one(
    "insert into todos (user_id, title) values ($1, $2) returning *",
    [userId, title.trim()],
  );
  return toTodo(row);
}

export async function updateTodo(id: string, patch: TodoPatch): Promise<Todo> {
  const row = await db.one(
    "update todos set title = coalesce($2, title), done = coalesce($3, done) where id = $1 returning *",
    [id, patch.title ?? null, patch.done ?? null],
  );
  return toTodo(row);
}

function toTodo(row: any): Todo {
  return { id: row.id, title: row.title, done: row.done, createdAt: row.created_at };
}
EOF
cat > src/lib/types.ts <<'EOF'
export interface Todo {
  id: string;
  title: string;
  done: boolean;
  createdAt: Date;
}

export type TodoPatch = Partial<Pick<Todo, "title" | "done">>;
EOF
git rm -q src/lib/legacy-cache.ts
cat > src/api/rate-limit.ts <<'EOF'
const WINDOW_MS = 60_000;
const LIMIT = 100;
const hits = new Map<string, number[]>();

/** Returns true if this user is over 100 requests in the last minute. */
export function isRateLimited(userId: string, now = Date.now()): boolean {
  const recent = (hits.get(userId) ?? []).filter((t) => now - t < WINDOW_MS);
  recent.push(now);
  hits.set(userId, recent);
  return recent.length > LIMIT;
}
EOF
cat >> tests/todos.test.ts <<'EOF'

test("rejects empty titles", async () => {
  await expect(createTodo("u1", "   ")).rejects.toThrow("title is required");
});

test("hides done todos by default", async () => {
  const todo = await createTodo("u1", "ship it");
  await updateTodo(todo.id, { done: true });
  expect(await listTodos("u1")).not.toContainEqual(expect.objectContaining({ id: todo.id }));
});
EOF
sed -i '' 's/A tiny todo API used to try onramp./A tiny todo API used to try onramp.\n\nNow with validation, updates, and rate limiting./' README.md

echo "demo repo: $DIR"
git status --short
[ -n "${ONRAMP_NO_OPEN:-}" ] || onramp "$DIR"
