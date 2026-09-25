#!/usr/bin/env bash
# Creates a PR-shaped playground repo for trying Onramp without touching
# real work: an "origin" with main, a feature branch with several commits,
# uncommitted edits, a new untracked file and a deleted one, in several
# languages. Re-run any time to reset it (it's rebuilt from scratch).
#   ./scripts/playground.sh            # ~/dev/onramp-playground
#   ./scripts/playground.sh <dir>      # somewhere else
set -euo pipefail
DIR="${1:-$HOME/dev/onramp-playground}"
ORIGIN="$DIR.origin.git"
case "$DIR" in */onramp-playground*|*playground*) ;; *) echo "refusing to reset $DIR (name must contain 'playground')"; exit 1 ;; esac
rm -rf "$DIR" "$ORIGIN"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$DIR" 2>/dev/null
cd "$DIR"
git config user.name "${GIT_AUTHOR_NAME:-$(git config --global user.name || echo you)}"
git config user.email "${GIT_AUTHOR_EMAIL:-$(git config --global user.email || echo you@example.com)}"
commit() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -qam "$2"; }
w() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# ── main ────────────────────────────────────────────────────────────────
w README.md <<'EOF'
# invoices

Invoice service: API (TypeScript), web app (React), a worker (Rust) and
some ops scripts.
EOF
w package.json <<'EOF'
{
  "name": "invoices",
  "private": true,
  "workspaces": ["api", "web"],
  "scripts": { "test": "vitest run", "lint": "eslint ." }
}
EOF
w api/src/lib/money.ts <<'EOF'
/** Amounts are integer cents; never floats. */
export type Cents = number;

export function formatCents(amount: Cents, currency = "USD"): string {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(amount / 100);
}

export function sum(amounts: Cents[]): Cents {
  return amounts.reduce((total, a) => total + a, 0);
}
EOF
w api/src/invoices/invoice.service.ts <<'EOF'
import { db } from "../lib/db";
import { Cents, sum } from "../lib/money";
import { events } from "../lib/events";

export type InvoiceStatus = "draft" | "sent" | "paid" | "void";

export interface LineItem {
  description: string;
  quantity: number;
  unitPrice: Cents;
}

export interface Invoice {
  id: string;
  customerId: string;
  status: InvoiceStatus;
  items: LineItem[];
  dueAt: Date;
}

export function total(invoice: Invoice): Cents {
  return sum(invoice.items.map((i) => i.quantity * i.unitPrice));
}

export async function getInvoice(id: string): Promise<Invoice> {
  const row = await db.invoice.findUniqueOrThrow({ where: { id }, include: { items: true } });
  return toInvoice(row);
}

export async function listInvoices(customerId: string): Promise<Invoice[]> {
  const rows = await db.invoice.findMany({
    where: { customerId },
    include: { items: true },
    orderBy: { dueAt: "desc" },
  });
  return rows.map(toInvoice);
}

export async function sendInvoice(id: string): Promise<Invoice> {
  const invoice = await getInvoice(id);
  if (invoice.status !== "draft") {
    throw new Error(`invoice ${id} is ${invoice.status}, only drafts can be sent`);
  }
  await db.invoice.update({ where: { id }, data: { status: "sent" } });
  events.emit("invoice.sent", { id, customerId: invoice.customerId });
  return { ...invoice, status: "sent" };
}

export async function markPaid(id: string): Promise<Invoice> {
  const invoice = await getInvoice(id);
  if (invoice.status !== "sent") {
    throw new Error(`invoice ${id} is ${invoice.status}, only sent invoices can be paid`);
  }
  await db.invoice.update({ where: { id }, data: { status: "paid" } });
  events.emit("invoice.paid", { id, customerId: invoice.customerId });
  return { ...invoice, status: "paid" };
}

export async function voidInvoice(id: string, reason: string): Promise<Invoice> {
  const invoice = await getInvoice(id);
  if (invoice.status === "paid") {
    throw new Error(`invoice ${id} is paid and can't be voided; refund it instead`);
  }
  await db.invoice.update({ where: { id }, data: { status: "void", voidReason: reason } });
  events.emit("invoice.voided", { id, reason });
  return { ...invoice, status: "void" };
}

export function isOverdue(invoice: Invoice, now = new Date()): boolean {
  return invoice.status === "sent" && invoice.dueAt < now;
}

function toInvoice(row: any): Invoice {
  return {
    id: row.id,
    customerId: row.customerId,
    status: row.status,
    items: row.items.map((i: any) => ({ description: i.description, quantity: i.quantity, unitPrice: i.unitPrice })),
    dueAt: new Date(row.dueAt),
  };
}
EOF
w api/src/invoices/invoice.routes.ts <<'EOF'
import { Router } from "express";
import { getInvoice, listInvoices, markPaid, sendInvoice, voidInvoice } from "./invoice.service";

export const invoiceRoutes = Router();

invoiceRoutes.get("/customers/:customerId/invoices", async (req, res) => {
  res.json(await listInvoices(req.params.customerId));
});

invoiceRoutes.get("/invoices/:id", async (req, res) => {
  res.json(await getInvoice(req.params.id));
});

invoiceRoutes.post("/invoices/:id/send", async (req, res) => {
  res.json(await sendInvoice(req.params.id));
});

invoiceRoutes.post("/invoices/:id/paid", async (req, res) => {
  res.json(await markPaid(req.params.id));
});

invoiceRoutes.post("/invoices/:id/void", async (req, res) => {
  res.json(await voidInvoice(req.params.id, req.body.reason));
});
EOF
w api/src/legacy/pdf.ts <<'EOF'
// Old PDF renderer, replaced by the worker's renderer.
export function renderPdf(html: string): Buffer {
  throw new Error("use the worker: POST /render");
}
EOF
w web/src/components/InvoiceTable.tsx <<'EOF'
import { formatCents } from "../../../api/src/lib/money";
import type { Invoice } from "../../../api/src/invoices/invoice.service";
import "../styles/table.css";

export function InvoiceTable({ invoices }: { invoices: Invoice[] }) {
  return (
    <table className="invoices">
      <thead>
        <tr>
          <th>Invoice</th>
          <th>Status</th>
          <th>Due</th>
        </tr>
      </thead>
      <tbody>
        {invoices.map((invoice) => (
          <tr key={invoice.id}>
            <td>{invoice.id}</td>
            <td className={`status status-${invoice.status}`}>{invoice.status}</td>
            <td>{invoice.dueAt.toLocaleDateString()}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
EOF
w web/src/styles/table.css <<'EOF'
table.invoices {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
}

table.invoices th {
  text-align: left;
  color: #57606a;
}

.status-paid { color: #1a7f37; }
.status-void { color: #8c959f; text-decoration: line-through; }
EOF
w worker/Cargo.toml <<'EOF'
[package]
name = "invoice-worker"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full"] }
EOF
w worker/src/main.rs <<'EOF'
use std::time::Duration;

/// Renders invoice PDFs from a queue.
#[tokio::main]
async fn main() {
    let queue = Queue::connect("redis://localhost").await;
    loop {
        match queue.next().await {
            Some(job) => render(job).await,
            None => tokio::time::sleep(Duration::from_millis(500)).await,
        }
    }
}

async fn render(job: Job) {
    let html = job.html();
    let pdf = pdf::from_html(&html).expect("render failed");
    job.complete(pdf).await;
}
EOF
w pkg/ratelimit/ratelimit.go <<'EOF'
package ratelimit

import (
	"sync"
	"time"
)

// Limiter allows n events per window per key.
type Limiter struct {
	mu     sync.Mutex
	n      int
	window time.Duration
	seen   map[string][]time.Time
}

func New(n int, window time.Duration) *Limiter {
	return &Limiter{n: n, window: window, seen: map[string][]time.Time{}}
}

func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	times := l.seen[key]
	if len(times) >= l.n {
		return false
	}
	l.seen[key] = append(times, now)
	return true
}
EOF
w scripts/backfill_balances.py <<'EOF'
"""One-off: backfill invoice balances."""
import sys

from db import connect


def main(dry_run: bool) -> None:
    conn = connect()
    for invoice in conn.query("select id from invoices where status = 'sent'"):
        print(f"would backfill {invoice.id}")


if __name__ == "__main__":
    main(dry_run="--apply" not in sys.argv)
EOF
w deploy/worker.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: invoice-worker
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: worker
          image: invoices/worker:latest
          resources:
            limits:
              memory: 256Mi
EOF
git add -A
commit "2026-09-01T10:00:00" "invoices: initial service, web table, worker"
git push -q origin main 2>/dev/null
git remote set-head origin main >/dev/null 2>&1 || true

# ── feat/partial-payments ───────────────────────────────────────────────
git checkout -q -b feat/partial-payments

# 1. money + service: partial payments
python3 - <<'PY'
import re
p = "api/src/lib/money.ts"
s = open(p).read()
s += '''
/**
 * Split `amount` into parts proportional to `weights`, handing leftover
 * cents to the first parts so the parts always add up to `amount`.
 */
export function allocate(amount: Cents, weights: number[]): Cents[] {
  const totalWeight = weights.reduce((a, w) => a + w, 0);
  const parts = weights.map((w) => Math.floor((amount * w) / totalWeight));
  let leftover = amount - sum(parts);
  for (let i = 0; leftover > 0; i = (i + 1) % parts.length, leftover--) parts[i]++;
  return parts;
}
'''
open(p, "w").write(s)

p = "api/src/invoices/invoice.service.ts"
s = open(p).read()
s = s.replace('export type InvoiceStatus = "draft" | "sent" | "paid" | "void";',
              'export type InvoiceStatus = "draft" | "sent" | "partially_paid" | "paid" | "void";')
s = s.replace('''  items: LineItem[];
  dueAt: Date;
}''', '''  items: LineItem[];
  payments: Payment[];
  dueAt: Date;
}

export interface Payment {
  amount: Cents;
  paidAt: Date;
}''')
s = s.replace('''export async function markPaid(id: string): Promise<Invoice> {
  const invoice = await getInvoice(id);
  if (invoice.status !== "sent") {
    throw new Error(`invoice ${id} is ${invoice.status}, only sent invoices can be paid`);
  }
  await db.invoice.update({ where: { id }, data: { status: "paid" } });
  events.emit("invoice.paid", { id, customerId: invoice.customerId });
  return { ...invoice, status: "paid" };
}''', '''export function balance(invoice: Invoice): Cents {
  return total(invoice) - sum(invoice.payments.map((p) => p.amount));
}

/** Record a payment; the invoice is paid once nothing is left owing. */
export async function recordPayment(id: string, amount: Cents): Promise<Invoice> {
  const invoice = await getInvoice(id);
  if (invoice.status !== "sent" && invoice.status !== "partially_paid") {
    throw new Error(`invoice ${id} is ${invoice.status}, only sent invoices take payments`);
  }
  if (amount <= 0 || amount > balance(invoice)) {
    throw new Error(`payment of ${amount} doesn't fit a balance of ${balance(invoice)}`);
  }
  const payments = [...invoice.payments, { amount, paidAt: new Date() }];
  const status = sum(payments.map((p) => p.amount)) === total(invoice) ? "paid" : "partially_paid";
  await db.invoice.update({ where: { id }, data: { status, payments: { create: { amount } } } });
  events.emit(status === "paid" ? "invoice.paid" : "invoice.payment_received", { id, amount });
  return { ...invoice, status, payments };
}''')
s = s.replace('''  return invoice.status === "sent" && invoice.dueAt < now;''',
              '''  return (invoice.status === "sent" || invoice.status === "partially_paid") && invoice.dueAt < now;''')
s = s.replace('''    dueAt: new Date(row.dueAt),''', '''    payments: row.payments.map((p: any) => ({ amount: p.amount, paidAt: new Date(p.paidAt) })),
    dueAt: new Date(row.dueAt),''')
s = s.replace('include: { items: true }', 'include: { items: true, payments: true }')
open(p, "w").write(s)
PY
commit "2026-09-02T09:30:00" "invoices: record partial payments, track balance"

# 2. routes + tests
python3 - <<'PY'
p = "api/src/invoices/invoice.routes.ts"
s = open(p).read()
s = s.replace("markPaid,", "recordPayment,")
s = s.replace('''invoiceRoutes.post("/invoices/:id/paid", async (req, res) => {
  res.json(await markPaid(req.params.id));
});''', '''invoiceRoutes.post("/invoices/:id/payments", async (req, res) => {
  const amount = Number(req.body.amount);
  if (!Number.isInteger(amount)) return res.status(400).json({ error: "amount must be integer cents" });
  res.json(await recordPayment(req.params.id, amount));
});''')
open(p, "w").write(s)
PY
w api/src/invoices/payments.test.ts <<'EOF'
import { describe, expect, it } from "vitest";
import { allocate } from "../lib/money";
import { balance, type Invoice } from "./invoice.service";

const invoice = (payments: number[]): Invoice => ({
  id: "inv_1",
  customerId: "cus_1",
  status: "sent",
  items: [{ description: "Consulting", quantity: 3, unitPrice: 10_000 }],
  payments: payments.map((amount) => ({ amount, paidAt: new Date() })),
  dueAt: new Date("2026-10-01"),
});

describe("balance", () => {
  it("is the total when nothing is paid", () => {
    expect(balance(invoice([]))).toBe(30_000);
  });

  it("goes down with each payment", () => {
    expect(balance(invoice([10_000, 5_000]))).toBe(15_000);
  });
});

describe("allocate", () => {
  it("never loses a cent", () => {
    const parts = allocate(100, [1, 1, 1]);
    expect(parts).toEqual([34, 33, 33]);
    expect(parts.reduce((a, b) => a + b)).toBe(100);
  });
});
EOF
git add -A
commit "2026-09-02T14:10:00" "invoices: POST /payments replaces /paid, with tests"

# 3. web: show balance; drop the legacy renderer
python3 - <<'PY'
p = "web/src/components/InvoiceTable.tsx"
s = open(p).read()
s = s.replace('import type { Invoice } from "../../../api/src/invoices/invoice.service";',
              'import { balance, type Invoice } from "../../../api/src/invoices/invoice.service";')
s = s.replace('''          <th>Due</th>
        </tr>''', '''          <th>Due</th>
          <th className="amount">Balance</th>
        </tr>''')
s = s.replace('''            <td>{invoice.dueAt.toLocaleDateString()}</td>
          </tr>''', '''            <td>{invoice.dueAt.toLocaleDateString()}</td>
            <td className="amount">{formatCents(balance(invoice))}</td>
          </tr>''')
s = s.replace("{invoice.status}</td>", '{invoice.status.replace("_", " ")}</td>')
open(p, "w").write(s)
p = "web/src/styles/table.css"
s = open(p).read()
s = s.replace(".status-paid { color: #1a7f37; }", ".status-paid { color: #1a7f37; }\n.status-partially_paid { color: #9a6700; }")
s += "\n.amount {\n  text-align: right;\n  font-variant-numeric: tabular-nums;\n}\n"
open(p, "w").write(s)
PY
git rm -q api/src/legacy/pdf.ts
commit "2026-09-03T11:00:00" "web: show each invoice's balance; remove legacy PDF renderer"

# 4. worker retries + ops
python3 - <<'PY'
p = "worker/src/main.rs"
s = open(p).read()
s = s.replace('''async fn render(job: Job) {
    let html = job.html();
    let pdf = pdf::from_html(&html).expect("render failed");
    job.complete(pdf).await;
}''', '''const MAX_ATTEMPTS: u32 = 3;

async fn render(job: Job) {
    let html = job.html();
    for attempt in 1..=MAX_ATTEMPTS {
        match pdf::from_html(&html) {
            Ok(pdf) => return job.complete(pdf).await,
            Err(e) if attempt < MAX_ATTEMPTS => {
                eprintln!("render attempt {attempt} failed: {e}; retrying");
                tokio::time::sleep(Duration::from_secs(2u64.pow(attempt))).await;
            }
            Err(e) => return job.fail(format!("render failed after {MAX_ATTEMPTS} attempts: {e}")).await,
        }
    }
}''')
open(p, "w").write(s)
p = "scripts/backfill_balances.py"
s = open(p).read()
s = s.replace('''    for invoice in conn.query("select id from invoices where status = 'sent'"):
        print(f"would backfill {invoice.id}")''', '''    rows = conn.query("select id, total, paid from invoices where status in ('sent', 'partially_paid')")
    for invoice in rows:
        balance = invoice.total - invoice.paid
        if dry_run:
            print(f"{invoice.id}: balance {balance}")
        else:
            conn.execute("update invoices set balance = %s where id = %s", (balance, invoice.id))
    print(f"{len(rows)} invoices {'checked' if dry_run else 'updated'}")''')
open(p, "w").write(s)
p = "deploy/worker.yaml"
s = open(p).read().replace("replicas: 1", "replicas: 2").replace("memory: 256Mi", "memory: 512Mi")
open(p, "w").write(s)
PY
commit "2026-09-04T16:45:00" "worker: retry renders with backoff; backfill script; 2 replicas"

# ── uncommitted work in progress ────────────────────────────────────────
python3 - <<'PY'
p = "pkg/ratelimit/ratelimit.go"
s = open(p).read()
s = s.replace('''	now := time.Now()
	times := l.seen[key]
	if len(times) >= l.n {''', '''	now := time.Now()
	// Forget events that fell out of the window, or keys lock out forever.
	times := l.seen[key][:0]
	for _, t := range l.seen[key] {
		if now.Sub(t) < l.window {
			times = append(times, t)
		}
	}
	if len(times) >= l.n {
		l.seen[key] = times''')
open(p, "w").write(s)
p = "README.md"
s = open(p).read() + "\nPartial payments: `POST /invoices/:id/payments` with `{ amount }` in cents.\n"
open(p, "w").write(s)
PY
w web/src/hooks/useBalance.ts <<'EOF'
import { useMemo } from "react";
import { balance, type Invoice } from "../../../api/src/invoices/invoice.service";

/** Balance owed across a customer's open invoices. */
export function useOutstanding(invoices: Invoice[]): number {
  return useMemo(
    () => invoices.filter((i) => i.status !== "void").reduce((owed, i) => owed + balance(i), 0),
    [invoices],
  );
}
EOF

echo "playground: $DIR"
echo "  branch feat/partial-payments: $(git rev-list --count origin/main..HEAD) commits ahead of origin/main"
echo "  $(git diff --name-only origin/main | wc -l | tr -d ' ') files changed vs origin/main, $(git status --short | wc -l | tr -d ' ') uncommitted"
[ -n "${ONRAMP_NO_OPEN:-}" ] || onramp "$DIR"
