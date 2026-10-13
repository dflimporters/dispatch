import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

const ACUMATICA_BASE = "https://dflimporters.acumatica.com/odata/dfl%20importers";
const ACUMATICA_USER = Deno.env.get("ACUMATICA_USERNAME") ?? "";
const ACUMATICA_PASS = Deno.env.get("ACUMATICA_PASSWORD") ?? "";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const PAGE_SIZE = 500;

const SELECT_FIELDS =
  "OrderType,OrderNbr,LineNbr,OrderDate,OrderStatus,OrderTotal," +
  "CustomerID,CustomerName,CustomerClassID,InventoryID,Linedescription,ItemClass," +
  "OrderQty,OpenQty,TotalQOHAllwarehouses,QtyOnHand71,QtyOnHandAsh," +
  "UnitPrice,ExtPrice,UnitCost,ExtCost," +
  "UnitMargin,ExtMargin,ExtMargin_2,Address1,Address2,City,State," +
  "ShippingZone,Salesperson,SalesArea,Merchandiser,Volume,Latencydays," +
  "IsaKeyItem,BulkItem";

function get14DaysAgoDate(): string {
  const d = new Date();
  d.setDate(d.getDate() - 14);
  return d.toISOString().split("T")[0];
}

function mapRecord(item: Record<string, unknown>) {
  return {
    order_nbr:         String(item.OrderNbr ?? "").trim(),
    line_nbr:          Number(item.LineNbr),
    order_type:        String(item.OrderType ?? "").trim(),
    order_date:        item.OrderDate ? String(item.OrderDate).split("T")[0] : null,
    order_status:      String(item.OrderStatus ?? "").trim(),
    order_total:       item.OrderTotal != null ? Number(item.OrderTotal) : null,
    customer_id:       String(item.CustomerID ?? "").trim(),
    customer_name:     String(item.CustomerName ?? "").trim(),
    customer_class_id: String(item.CustomerClassID ?? "").trim(),
    inventory_id:      String(item.InventoryID ?? "").trim(),
    line_description:  String(item.Linedescription ?? "").trim(),
    item_class:        String(item.ItemClass ?? "").trim(),
    order_qty:         item.OrderQty != null ? Number(item.OrderQty) : null,
    open_qty:          item.OpenQty != null ? Number(item.OpenQty) : null,
    qty_on_hand:       item.TotalQOHAllwarehouses != null ? Number(item.TotalQOHAllwarehouses) : null,
    qty_on_hand_71:    item.QtyOnHand71 != null ? Number(item.QtyOnHand71) : null,
    qty_on_hand_ash:   item.QtyOnHandAsh != null ? Number(item.QtyOnHandAsh) : null,
    unit_price:        item.UnitPrice != null ? Number(item.UnitPrice) : null,
    ext_price:         item.ExtPrice != null ? Number(item.ExtPrice) : null,
    unit_cost:         item.UnitCost != null ? Number(item.UnitCost) : null,
    ext_cost:          item.ExtCost != null ? Number(item.ExtCost) : null,
    unit_margin:       item.UnitMargin != null ? Number(item.UnitMargin) : null,
    ext_margin:        item.ExtMargin != null ? Number(item.ExtMargin) : null,
    margin_pct:        item.ExtMargin_2 != null ? Number(item.ExtMargin_2) : null,
    address1:          item.Address1 ? String(item.Address1).trim() : null,
    address2:          item.Address2 ? String(item.Address2).trim() : null,
    city:              item.City ? String(item.City).trim() : null,
    state:             item.State ? String(item.State).trim() : null,
    shipping_zone:     item.ShippingZone ? String(item.ShippingZone).trim() : null,
    salesperson:       String(item.Salesperson ?? "").trim(),
    sales_area:        String(item.SalesArea ?? "").trim(),
    merchandiser:      item.Merchandiser ? String(item.Merchandiser).trim() : null,
    volume:            item.Volume != null ? Number(item.Volume) : null,
    latency_days:      item.Latencydays != null ? Number(item.Latencydays) : null,
    is_key_item:       item.IsaKeyItem ? String(item.IsaKeyItem).trim() : null,
    bulk_item:         item.BulkItem ? String(item.BulkItem).trim() : null,
    synced_at:         new Date().toISOString(),
  };
}

type PassResult = { upserted: number; statusChanges: number; error?: string; detail?: string };

// One paged fetch+upsert pass over SOOrderedItems for a given OData $filter.
async function runPass(
  supabase: SupabaseClient,
  authHeader: string,
  filter: string,
): Promise<PassResult> {
  let skip = 0;
  let upserted = 0;
  let statusChanges = 0;
  let hasMore = true;

  while (hasMore) {
    const url =
      `${ACUMATICA_BASE}/SOOrderedItems` +
      `?$top=${PAGE_SIZE}&$skip=${skip}` +
      `&$filter=${filter}` +
      `&$select=${SELECT_FIELDS}`;

    const res = await fetch(url, { headers: { Authorization: authHeader, Accept: "application/json" } });
    if (!res.ok) {
      return { upserted, statusChanges, error: `Acumatica fetch failed: ${res.status}`, detail: await res.text() };
    }

    const json = await res.json();
    const items: Record<string, unknown>[] = json.value ?? [];
    if (items.length === 0) break;

    const rows = items.map(mapRecord);

    // Status-change audit vs. currently stored status (line 1 as the representative row).
    const incoming = new Map<string, string>();
    for (const r of rows) if (!incoming.has(r.order_nbr)) incoming.set(r.order_nbr, r.order_status);
    const orderNbrs = Array.from(incoming.keys());

    const { data: existingRows } = await supabase
      .from("so_ordered_items")
      .select("order_nbr, order_status")
      .in("order_nbr", orderNbrs)
      .eq("line_nbr", 1);

    const existing = new Map<string, string>();
    for (const r of existingRows ?? []) existing.set(r.order_nbr, r.order_status);

    const now = new Date().toISOString();
    const history: { order_nbr: string; old_status: string | null; new_status: string; detected_at: string }[] = [];
    for (const [nbr, newStatus] of incoming.entries()) {
      const oldStatus = existing.get(nbr) ?? null;
      if (oldStatus !== newStatus) history.push({ order_nbr: nbr, old_status: oldStatus, new_status: newStatus, detected_at: now });
    }
    if (history.length > 0) {
      const { error: hErr } = await supabase.from("so_order_status_history").insert(history);
      if (hErr) return { upserted, statusChanges, error: "History insert failed", detail: hErr.message };
      statusChanges += history.length;
    }

    const { error } = await supabase.from("so_ordered_items").upsert(rows, { onConflict: "order_nbr,line_nbr" });
    if (error) return { upserted, statusChanges, error: "Supabase upsert failed", detail: error.message };

    upserted += rows.length;
    skip += PAGE_SIZE;
    if (items.length < PAGE_SIZE) hasMore = false;
  }

  return { upserted, statusChanges };
}

Deno.serve(async (req) => {
  // Only the scheduled job (Vault dispatch_cron_token) may run this.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const { data: ok } = token ? await supabase.rpc("dispatch_cron_ok", { p_token: token }) : { data: false };
  if (!ok) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "Content-Type": "application/json" } });

  const runStarted = new Date().toISOString(); // capture BEFORE any fetch
  const authHeader = "Basic " + btoa(`${ACUMATICA_USER}:${ACUMATICA_PASS}`);

  // Phase A — recent pass: last 14 days by OrderDate, all statuses.
  const cutoff = get14DaysAgoDate();
  const passA = await runPass(supabase, authHeader, `OrderDate ge datetime'${cutoff}T00:00:00'`);
  if (passA.error) {
    return new Response(JSON.stringify({ phase: "A", ...passA }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  // Phase B — live pass: all open commitments regardless of age, no date limit.
  const passB = await runPass(supabase, authHeader, `OrderStatus eq 'Open' or OrderStatus eq 'Back Order'`);
  if (passB.error) {
    return new Response(JSON.stringify({ phase: "B", ...passB }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  // Phase C — reconcile the untouched tail against authoritative sales_orders status.
  const { data: reconciled, error: rErr } = await supabase.rpc("reconcile_so_line_status", { p_run_started: runStarted });
  if (rErr) {
    return new Response(JSON.stringify({ phase: "C", error: "Reconcile failed", detail: rErr.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  return new Response(
    JSON.stringify({
      success: true,
      run_started: runStarted,
      recent_pass:   { rows_upserted: passA.upserted, status_changes: passA.statusChanges },
      live_pass:     { rows_upserted: passB.upserted, status_changes: passB.statusChanges },
      reconciled_lines: reconciled,
      cutoff_date: cutoff,
    }),
    { headers: { "Content-Type": "application/json" } }
  );
});
