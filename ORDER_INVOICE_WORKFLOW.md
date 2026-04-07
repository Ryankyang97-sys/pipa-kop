# PiPa KOP — Order & Invoice Workflow Spec
**Version:** 2.0 — rewritten with full app context  
**Date:** 04/07/2026  
**Author:** Ryan Yang · Beverage Lead, EKP  
**Scope:** pipa-count.html → pipa-ops.html Orders tab → pipa-ops.html Invoices tab → Trend

---

## The Problem (as-built vs. intended)

There are currently **three separate, disconnected systems** that all hold "what do I have on hand":

| System | Where count lives | Who writes it | Connected to orders? |
|---|---|---|---|
| `pipa-count.html` | `inventory_trend` table (Supabase) | Ryan (walk-route) | No |
| Orders tab | `order_counts` table (Supabase) | Ryan (manual entry in Orders UI) | Partially |
| Invoices tab | `localStorage` → `invoices[]` array | Ryan (manual) | No |

The result: after doing a full count in pipa-count, Ryan still has to manually re-enter those same numbers into the Orders tab count fields before a suggested order quantity appears. The invoice form has no awareness of either. Each step starts from zero.

**The intended flow is:**

```
Count (pipa-count) → auto-populates Orders tab → Ryan reviews/adjusts pars →
creates Invoice for a vendor (pre-filled with confirmed qtys) →
marks delivery received → updates trend
```

No number should need to be typed twice.

---

## Current Architecture (what actually exists)

### pipa-count.html
- Walk-route inventory: Cellar / Cage / Walk-in / Back Bar
- On submit: writes to `inventory_trend` table (snap_date, d365, item_name, category, count)
- Count is the sum of all location fields per item
- Exports CSV: Date, Sheet, Row, D365#, Item, Field, Count, Flag, Note
- **Does not write to `order_counts`** — the two systems are fully siloed

### pipa-ops.html — Orders tab
- Item master is a hardcoded JS object: `ORDER_VENDORS` (~200 items across 13 vendors)
- Each item has: d365, name, cat, par, note, vendor
- On load: reads `order_counts` for count_date = TODAY → populates `opCounts{}` map
- Count fields are **manual input** in the UI — Ryan types numbers into each row
- Suggested order = max(0, par - entered_count) — computed client-side in real time
- Save: writes entered counts to `order_counts` table
- Par edits: go through `order_items_overrides` table (upsert on d365+vendor)
- Copy order: assembles text of items where suggested > 0 → clipboard
- Snapshot export: generates XLSX per vendor

### pipa-ops.html — Invoices tab
- Stored in **localStorage** as `invoices[]` — not in Supabase
- Invoice has: id, vendor, date, po, invoiceNum, amount, discrepancy, checks{}, notes
- No ordered line items are stored — the invoice is just a header record
- "Log Items" opens a receipt sheet that reads from ORDER_VENDORS[vendor].items (the full item list, not an order-specific list)
- Receipt quantities saved to `delivery_items` Supabase table (invoice_id, d365, qty_received, confirmed)
- On confirm: writes to delivery_items with confirmed=true
- **No connection to count data or suggested order quantities**

### pipa-ops.html — Trend tab
- Reads `inventory_trend` (count snapshots) + `delivery_items` (confirmed receives) in parallel
- Groups by d365, computes avg weekly depletion
- Shows weeks-to-stockout, last count, total received
- This part works correctly

---

## What Needs to Change — Four Gaps

### Gap 1: Count → Orders (highest priority)

**Problem:** pipa-count writes to `inventory_trend`. Orders tab reads from `order_counts`. No overlap.

**Fix:** When pipa-count submits, also upsert to `order_counts`. On next Orders tab open, opCounts{} is pre-populated — no re-entry needed.

Change in **pipa-count.html**, in the existing Supabase submit handler:

```js
// existing write — keep unchanged
supa.from('inventory_trend').upsert(trendRows, { onConflict: 'snap_date,d365' });

// NEW: mirror to order_counts so Orders tab auto-loads today's count
var orderRows = trendRows.map(function(r) {
  return {
    count_date: r.snap_date,
    d365:       r.d365,
    item_name:  r.item_name,
    category:   r.category,
    vendor:     null,   // Orders tab fills this from its own ORDER_VENDORS
    par:        null,   // Orders tab fills this from its own ORDER_VENDORS
    count:      r.count,
    order_qty:  null    // recalculated in Orders tab when it loads
  };
});
supa.from('order_counts').upsert(orderRows, { onConflict: 'count_date,d365' });
```

The Orders tab already reads order_counts on load and merges into opCounts{} — no changes needed there. It already handles items where vendor/par are null by using its own ORDER_VENDORS data.

---

### Gap 2: Orders → Invoice pre-fill

**Problem:** Invoices are created from scratch. No connection to what was just reviewed in Orders.

**Fix:** Add a "Create Invoice" button to each vendor card in the Orders tab. It captures the current suggested quantities and pre-fills a new invoice with them as line items.

**New button** in `_renderOPVendor()`:

```js
var createInvBtn = itemsNeedOrder > 0
  ? '<button class="op-copy-btn" onclick="createInvoiceFromOrder(\'' + v.name + '\')" ' +
    'style="background:var(--accent-dim);color:var(--accent-bright);border-top:1px solid var(--surface3);">' +
    '🧾 Create Invoice — ' + v.name + ' (' + itemsNeedOrder + ' items)</button>'
  : '';
```

**New function** `createInvoiceFromOrder(vendorName)`:

```js
function createInvoiceFromOrder(vendorName) {
  var v = ORDER_VENDORS[vendorName];
  if (!v) return;

  var lineItems = v.items
    .filter(function(item) {
      var count = opCounts[item.d365];
      return opSuggest(item.par, count !== undefined ? count : null) > 0;
    })
    .map(function(item) {
      var count = opCounts[item.d365];
      return {
        d365:          item.d365,
        name:          item.name,
        cat:           item.cat,
        ordered_qty:   opSuggest(item.par, count),
        received_qty:  null,
        count_on_hand: count || 0
      };
    });

  var inv = {
    id:          'inv-' + Date.now(),
    vendor:      vendorName,
    date:        TODAY,
    po:          '',
    invoiceNum:  '',
    amount:      '',
    discrepancy: false,
    checks:      { received: false, d365: false, sentIC: false, pricingOK: false },
    notes:       '',
    lineItems:   lineItems,   // NEW — stores ordered quantities
    status:      'draft'
  };

  invoices.unshift(inv);
  save('invoices', invoices);
  switchView('invoices');
  toast('Invoice drafted — ' + lineItems.length + ' items from ' + vendorName);
}
```

**Update `openReceiptSheet()`** to prefer invoice line items over the full vendor list:

```js
// In openReceiptSheet(invId, vendor, date):
var inv   = invoices.find(function(i) { return i.id === invId; });
var items = (inv && inv.lineItems && inv.lineItems.length)
              ? inv.lineItems           // use ordered line items when available
              : (ORDER_VENDORS[vendor] ? ORDER_VENDORS[vendor].items : []);
```

This means the receiving form shows exactly what was ordered rather than the full 200-item vendor catalog.

---

### Gap 3: Receiving → Order counts update

**Problem:** After confirming a receipt, the current count in order_counts is not updated. The next Orders tab open still shows the pre-delivery count.

**Fix:** After `delivery_items` insert confirms successfully, upsert to `order_counts` incrementing count by received_qty.

Change in `_saveReceiptItems()`, inside the `.then()` block after confirmed insert:

```js
if (confirmed) {
  // existing inventory_trend write (if any) stays here

  // NEW: update order_counts to reflect post-delivery stock
  var updates = rows.map(function(row) {
    var prior = opCounts[row.d365] || 0;
    return {
      count_date: TODAY,
      d365:       row.d365,
      item_name:  row.item_name,
      category:   itemMap[row.d365] ? itemMap[row.d365].cat : '',
      vendor:     row.vendor,
      count:      prior + row.qty_received,
      order_qty:  0
    };
  });
  supa.from('order_counts').upsert(updates, { onConflict: 'count_date,d365' });

  // Update local opCounts map so UI reflects it immediately
  rows.forEach(function(row) {
    opCounts[row.d365] = (opCounts[row.d365] || 0) + row.qty_received;
  });

  if (cb) cb();
}
```

---

### Gap 4: Invoice persistence — localStorage → Supabase

**Problem:** Invoices disappear if browser cache clears. Not accessible from another device. No audit trail.

**New Supabase table:**

```sql
CREATE TABLE invoices (
  id           text PRIMARY KEY,
  vendor       text NOT NULL,
  order_date   date NOT NULL DEFAULT CURRENT_DATE,
  po_number    text,
  invoice_num  text,
  amount       numeric,
  status       text DEFAULT 'draft',
  discrepancy  boolean DEFAULT false,
  line_items   jsonb DEFAULT '[]',
  checks       jsonb DEFAULT '{}',
  notes        text,
  created_at   timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now()
);
```

`line_items` JSONB element structure:
```json
{
  "d365":          "1136347",
  "name":          "Prosecco",
  "cat":           "BTG WINE",
  "ordered_qty":   3,
  "received_qty":  null,
  "count_on_hand": 73
}
```

Status lifecycle: `draft → ordered → received → verified`

**Replace localStorage calls** with Supabase reads/writes using the existing `sbFetch` / supa pattern. On first load check localStorage for existing invoices and offer migration.

---

## Revised Data Flow (target state)

```
pipa-count.html
  │  on submit
  ├──► inventory_trend  (snap_date, d365, count)         ← unchanged
  └──► order_counts     (count_date, d365, count)         ← NEW

pipa-ops.html / Orders tab
  │  on load
  ├──► reads order_counts for TODAY → opCounts{}          ← already works
  │    (now pre-filled from pipa-count instead of blank)
  ├──► reads order_items_overrides → par/vendor merges    ← already works
  │
  └──► "Create Invoice" button ──► invoices table         ← NEW
       passes lineItems[] with suggested qtys

pipa-ops.html / Invoices tab
  │  on load
  ├──► reads invoices from Supabase                       ← changed from localStorage
  │
  └──► "Log Items" ──► receipt sheet uses inv.lineItems   ← changed: ordered items not full list
       "Confirm Receipt" ──► delivery_items (confirmed)   ← unchanged
                          └► order_counts +=received_qty  ← NEW

pipa-ops.html / Trend tab
  └──► reads inventory_trend + delivery_items             ← unchanged, already works
```

---

## Supabase Tables Summary

| Table | Status | Written by | Read by |
|---|---|---|---|
| `inventory_trend` | Exists | pipa-count (count) | Trend tab |
| `order_counts` | Exists | Orders tab (manual) + pipa-count (NEW) + receiving (NEW) | Orders tab |
| `order_items_overrides` | Exists | Orders tab (par edits) | Orders tab |
| `delivery_items` | Exists | Invoices tab (receiving) | Trend tab |
| `invoices` | **New** | Invoices tab | Invoices tab |
| `activations_log` | Exists | Activations tab | Activations tab |
| `updates` | Exists | Ops updates composer | pipa-bar (realtime) |
| `pull_flags` | Exists | pipa-bar | pipa-bar (realtime) |

---

## Implementation Order

**1. Gap 1 — pipa-count → order_counts** (30 min, low risk)
One additional upsert call in pipa-count's existing submit handler. No schema changes.

**2. Gap 2 — "Create Invoice" from Orders** (2–3 hrs)
New button in `_renderOPVendor()`. New `createInvoiceFromOrder()` function. Update `openReceiptSheet()` to use inv.lineItems. Renders invoice card with line item detail view.

**3. Gap 3 — Receiving → order_counts update** (30 min, low risk)
Add upsert to `_saveReceiptItems()` after confirmed delivery_items write.

**4. Gap 4 — Invoices to Supabase** (3–4 hrs)
`invoices` table DDL. Rewrite invoice CRUD to use Supabase. localStorage migration on first load. Do this last — localStorage still works while other gaps are addressed.

---

## Open Questions

1. **Par lookup from pipa-count:** Writing null for par/vendor from pipa-count and letting Orders tab fill it from ORDER_VENDORS is the simplest path. Is that acceptable, or do we need pars in order_counts to be accurate for other read paths?

2. **"Create Invoice" always or only when items need ordering?** Current proposal: button only appears when suggested qty > 0 for that vendor. Edge case: Ryan might want to log a receipt for a vendor even if nothing was technically below par (e.g. a regular dairy delivery).

3. **Invoice status gating:** Should advancing from `draft → ordered` require a PO# to be entered first?

4. **Multiple partial deliveries:** If SGWS delivers in two shipments, should it be one invoice with two receipt events (already supported by delivery_items), or two invoices? Recommend one invoice / multiple receipt events — the UI just needs an "Add Another Receipt" action on an existing invoice rather than locking after first confirmation.

---

*End of spec. Implement Gap 1 first — it's the smallest change with the most immediate payoff.*
