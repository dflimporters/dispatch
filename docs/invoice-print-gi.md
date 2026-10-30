# Invoice print: Acumatica Generic Inquiry and data contract

Goal: print the DFL tax invoice (report SO643000, `so643000.rpx`) from the dispatch portal on US Letter, matching the Acumatica form, using data read from Acumatica. The portal's old sync (`invoices`, `invoiced_items`) lacks UOM, city, terms, due date, PO, bill/ship names, line notes and per-line tax, so one new Generic Inquiry carries everything the report uses.

## 1. Build the GI (Acumatica TEST first, then live)

Screen: Generic Inquiry (SM208000). Make it on TEST, then export the GI and import to live.

- **Inquiry Title:** `DFL Invoice Print`
- **Inquiry ID / OData name:** `DFLInvoicePrint`
- **Expose via OData:** ticked (also "Expose via Generic Inquiry... OData")
- **Results grid:** one row per invoice line.
- **Access rights:** give the API user (the same one `sync-so-invoices` uses) access to this GI.

### Tables (Tables tab). Add in this order, joins on the right

| Alias | Table | Join |
|---|---|---|
| Inv | ARInvoice (primary) | none |
| Tran | ARTran | Tran.TranType = Inv.DocType AND Tran.RefNbr = Inv.RefNbr |
| Item | InventoryItem | Item.InventoryID = Tran.InventoryID (left join) |
| Terms | Terms | Terms.TermsID = Inv.TermsID (left) |
| Ord | SOOrder | Ord.OrderType = Tran.SOOrderType AND Ord.OrderNbr = Tran.SOOrderNbr (left) |
| BillAddr | ARAddress | BillAddr.AddressID = Inv.BillAddressID (left) |
| BillCont | ARContact | BillCont.ContactID = Inv.BillContactID (left) |
| SoInv | SOInvoice | SoInv.DocType = Inv.DocType AND SoInv.RefNbr = Inv.RefNbr (left). Add this BEFORE ShipAddr and ShipCont, which join through it |
| ShipAddr | SOShippingAddress | ShipAddr.AddressID = SoInv.ShipAddressID (left) |
| ShipCont | SOShippingContact | ShipCont.ContactID = SoInv.ShipContactID (left) |
| Cust | Customer | Cust.BAccountID = Inv.CustomerID (left) |
| LineNote | Note | LineNote.NoteID = Tran.NoteID (left) |

Check against the report: open `so643000.rpx` in Report Designer, **Fields** tab. The report's `BillingContact`, `BillingAddress`, `ShippingContact`, `ShippingAddress` show which tables they come from. If your 2024R2 uses different table names than the ones above, use the ones the report uses.

### Conditions (Conditions tab)

- Inv.DocType = `INV`
- Inv.Status IN (`Hold`, `Balanced`, `Open`, `Closed`). Printing happens BEFORE release, so Balanced must be included.
- Tran.Qty is not equal to 0 (skips void lines)

Add a **Parameter** only if you want to test inside Acumatica; the sync filters over OData by date.

### Result columns (Results Grid tab). Column header = the OData field name; keep these exactly

Header (same value on every line of the invoice):

| Field | Source |
|---|---|
| RefNbr | Inv.RefNbr |
| DocType | Inv.DocType |
| DocDate | Inv.DocDate |
| DueDate | Inv.DueDate |
| Status | Inv.Status |
| CustomerID | Inv.CustomerID (the CD / display value) |
| CustomerName | Cust.AcctName |
| CurrencyID | Inv.CuryID |
| TermsID | Inv.TermsID |
| TermsDescr | Terms.Descr |
| SalesPersonID | Ord.SalesPersonID |
| SONumber | Tran.SOOrderNbr |
| ShipmentNbr | Tran.SOShipmentNbr |
| CustomerPO | Ord.CustomerOrderNbr |
| CustomerRefNbr | Ord.CustomerRefNbr |
| ShipVia | Inv.ShipVia if present, else SoInv.ShipVia |
| BillName | BillCont.FullName |
| BillAddress1 | BillAddr.AddressLine1 |
| BillAddress2 | BillAddr.AddressLine2 |
| BillCity | BillAddr.City |
| BillState | BillAddr.State |
| BillCountry | BillAddr.CountryID |
| BillPostal | BillAddr.PostalCode |
| ShipName | ShipCont.FullName |
| ShipAddress1 | ShipAddr.AddressLine1 |
| ShipAddress2 | ShipAddr.AddressLine2 |
| ShipCity | ShipAddr.City |
| ShipState | ShipAddr.State |
| ShipCountry | ShipAddr.CountryID |
| ShipPostal | ShipAddr.PostalCode |
| SalesTotal | Inv.CuryLineTotal (the "Sales" box on the form) |
| DiscountTotal | Inv.CuryDiscTot |
| TaxTotal | Inv.CuryTaxTotal |
| DocTotal | Inv.CuryOrigDocAmt (the "Total (JMD)" box) |

Per line:

| Field | Source |
|---|---|
| LineNbr | Tran.LineNbr |
| InventoryCD | Item.InventoryCD |
| LineDescr | Tran.TranDesc |
| Qty | Tran.Qty |
| UOM | Tran.UOM |
| UnitPrice | Tran.CuryUnitPrice |
| TaxCategory | Tran.TaxCategoryID (`TAXABLE` or `NONTAXABLE`; the form shows TX for taxable) |
| ItemTaxCategory | Item.TaxCategoryID (the stock item's Tax Category, same two values; kept as a cross-check) |
| ExtAmount | Tran.CuryTranAmt |
| LineDiscount | Tran.CuryDiscAmt |
| LineNote | LineNote.NoteText |
| LastModified | Inv.LastModifiedDateTime (the sync uses this to pick up changes) |

Sort: Inv.RefNbr, Tran.LineNbr.

If the report shows a field differently from the above (for example the form's "Sales" total or the shipping contact), copy what the report uses. Save, run it once on TEST for invoice 1059165, and compare against `SO Invoice 1059165.pdf`:
Sales 114,710.60, Discount 0.00, Tax 17,206.60, Total 131,917.20; three lines at TX.

## 2. Tax rule used by the print

GCT is 15%. Each taxable line is rounded to 2 decimals (half up) and the rounded line taxes are summed; that must equal `TaxTotal` within 0.05. A line is taxable when `TaxCategory` is `TAXABLE` (or `TX`) and prints `TX`; `NONTAXABLE` prints `NT`. If the numbers don't reconcile, the portal refuses to print and says why. Only the one rate (15% GCT) exists.

## 3. Data contract (what the sync stores and the layout renders)

One object per invoice, as the layout expects it:

```json
{
  "ref": "1059165", "doc_type": "INV", "date": "2026-10-28", "due_date": "2026-11-27",
  "status": "Balanced", "customer_id": "C000000540", "currency": "JMD",
  "terms": "Due in 30 Days", "salesperson": "KC",
  "so_number": "208825", "shipment_nbr": "282168", "customer_po": null, "customer_ref": null, "ship_via": null,
  "bill": { "name": "BRAVO SUPERMARKET (no Friday delivery)", "lines": ["BRAVO SUPERMARKET, 5 BRAVO STREET", "ST. ANNS BAY", "Jamaica"] },
  "ship": { "name": "BRAVO SUPERMARKET (no Friday delivery)", "lines": ["BRAVO SUPERMARKET, 5 BRAVO STREET", "ST. ANNS BAY", "Jamaica"] },
  "sales_total": 114710.60, "discount_total": 0, "tax_total": 17206.60, "total": 131917.20,
  "lines": [
    { "n": 1, "item": "10000527", "descr": "Friendly Flame Gel Cooking Fuel 2.5 hour (72cans x 200g)", "qty": 5, "uom": "CASE",
      "unit_price": 8912.00, "tax_cat": "TX", "amount": 44560.00, "discount": 0, "note": null }
  ]
}
```

Company block on the form is fixed text: Decasseres Farm Limited, 71 Molynes Rd, Kingston 10, Phone: 1-876-622-6718; "TAX INVOICE", "GCT Ref # 000-439-363".
Footer text: "Damaged goods returned after 45 days will not be accepted by DFL. Returned cheques attract a fee of 1% of the total value returned." then the received-by and signature lines.
Sample for layout: `SO Invoice 1059165.pdf` in the dispatch folder (one level above the repo).

Supabase side (built by the sync agent): tables `invoice_print_headers` (one row per invoice, header fields above plus `bill`/`ship` jsonb) and `invoice_print_lines` (one row per line), both with RLS limited to supervisor and manager, and a function `invoice_print_fetch(p_refs text[])` returning an array of the objects above.
