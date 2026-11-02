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

**As built on TEST (2024R2), differences from the table above**
- Inquiry Title is `DFLInvoicePrint` (no spaces): Acumatica derives the OData name from the title. Aliases are the table defaults (ARInvoice, ARTran, InventoryItem, Terms, SOOrder, ARAddress, ARContact, SOInvoice, SOShippingAddress, SOShippingContact, Customer, Note), not Inv/Tran/etc.
- Customer is `PX.Objects.AR.Customer` (not the `AR-Customers` BI view). `CustomerID` is `Customer.AcctCD`; `TermsDescr` is `ARInvoice.TermsID_Description`.
- ARInvoice, SOInvoice and ARTran have no `ShipVia` field in 2024R2. `ShipVia` comes from `SOShipment.ShipVia` (extra Left join ARTran.SOShipmentType/SOShipmentNbr to SOShipment); `SOOrder.ShipVia` is unreliable.
- Add a floor on `ARInvoice.DocDate` (rolling `@@today-60` or a fixed date) so the OData result stays small. Use the stored status codes H, B, N, C if the labels fail with "Conversion failed when converting the varchar value 'B' to data type bit".
- TEST data is a copy from about 15 Oct 2026; invoice 1059165 is not there. Test invoice was 1034495 (4 lines, discounts per line, Sales 289,949.10, Tax 43,492.36, Total 333,441.46). Note the form's "Lines Total" (298,901.65) is the gross, and "Sales Total" is ARInvoice.CuryLineTotal, net of line discounts; line tax is 15% of the net line amount.

**OData field names as exposed (no captions were set; Acumatica's defaults).** URL: `https://dflimporters.acumatica.com/odata/TEST/DFLInvoicePrint` (live: same without TEST, or the live tenant name). All money and qty values arrive as strings; dates as ISO datetimes; `DefaultSalesperson` is space-padded (trim). A `_2` suffix is a second field with the same name, assigned by column order in the grid; do not reorder or delete grid rows without rechecking.

| Spec name | OData field | Spec name | OData field |
|---|---|---|---|
| RefNbr | ReferenceNbr | ShipName | AccountName_2 |
| DocType | Type | ShipAddress1/2 | AddressLine1_2 / AddressLine2_2 |
| DocDate | Date | ShipCity / ShipState | City_2 / State_2 |
| DueDate | DueDate | ShipCountry / ShipPostal | Country_2 / PostalCode_2 |
| Status | Status | SalesTotal | DetailTotal |
| CustomerID | CustomerID | DiscountTotal | GroupandDocumentDiscountTotal |
| CustomerName | CustomerName | TaxTotal | TaxTotal |
| CurrencyID | Currency | DocTotal | Amount |
| TermsID | Terms | LineNbr | LineNbr |
| TermsDescr | Description | InventoryCD | InventoryID |
| SalesPersonID | DefaultSalesperson | LineDescr | TransactionDescr |
| SONumber | OrderNbr | Qty | Quantity |
| ShipmentNbr | ShipmentNbr | UOM | UOM |
| CustomerPO | CustomerOrderNbr | UnitPrice | UnitPrice |
| CustomerRefNbr | ExternalReference | TaxCategory | TaxCategory |
| ShipVia | ShipVia | ItemTaxCategory | TaxCategory_2 |
| BillName | AccountName | ExtAmount | Amount_2 |
| BillAddress1/2 | AddressLine1 / AddressLine2 | LineDiscount | DiscountAmount |
| BillCity / BillState | City / State | LineNote | NoteText |
| BillCountry / BillPostal | Country / PostalCode | LastModified | LastModifiedOn |

Checked on invoice 1034003: DetailTotal 1,269,746.95 + TaxTotal 190,462.06 = Amount 1,460,209.01; Amount_2 221,081.00 = Quantity 50 x UnitPrice 4,421.62. PostalCode and PostalCode_2 were null on that row, so the bill/ship postal mapping is by column order and still to be confirmed on a row with a postal code. Other `ARTran`/join key fields (OrderType, OrderNbr_2, TranType, ContactID, AddressID, NoteID, TermsID...) also appear in the feed and can be ignored.

**Live decision:** the line note is not needed on the printed invoice, so on live the `Note` table, its ARTran join and the `LineNote` (`NoteText`) column are removed (the Note join was slow on the live database). The sync must treat `NoteText` as absent/null. TEST still has it. On live the `PostalCode` / `PostalCode_2` mapping is by grid order: the first `PostalCode` is the ship one (`SOShippingAddress`), `PostalCode_2` is the bill one; neither is printed.

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

### 1b. Fallback if the GI OData call will not run on live (REST instead)

State on 2026-11-02: `DFLInvoicePrint` works in View Inquiry on live (a few seconds) and the OData feed worked on TEST, but on live `/odata/DFL Importers/DFLInvoicePrint?$top=1` (even with `$select=ReferenceNbr`) hangs and ends with `ERR_HTTP2_PROTOCOL_ERROR`, while the existing `InvoicedItems` GI answers instantly. Cause not found (a stripped-down copy of the GI would bisect it).

Use Acumatica's contract-based REST API instead, one call per invoice, so no GI query is involved:
- Log in with the API user: `POST https://dflimporters.acumatica.com/entity/auth/login` with name, password and company `DFL Importers` (cookie session), and `POST .../entity/auth/logout` after.
- Fetch: `GET https://dflimporters.acumatica.com/entity/Default/24.200.001/Invoice?$filter=ReferenceNbr eq '1059165'&$expand=Details` (the AR Invoice entity). The SO `SalesInvoice` entity is the alternative if ship-to data, shipment number or ShipVia are only there.
- Not yet verified against live: which fields these entities expose. Before coding the sync, read the entity definition (`.../entity/Default/24.200.001/$adHocSchema` on `Invoice`, or the swagger at `/entity/Default/24.200.001/swagger.json`) and map to the data contract in section 3. Fields most likely to need a second source: ShipVia (not on ARInvoice/SOInvoice/ARTran; GI used `SOShipment.ShipVia`), SO number and shipment number per line, bill/ship name, stock-item tax category, per-line TaxCategory.
- Use `$select` and `$expand` to limit the payload, call per invoice (or small batches by RefNbr), and keep the date/LastModified filter for picking up changes.

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

## 4. REST field mapping used by `sync-invoice-print` (replaces the GI/OData feed)

Verified on live 2026-11-02 against invoice 1059165 (read-only, via a temporary probe; endpoint Default/24.200.001). Login once per run (`POST /entity/auth/login`, company `DFL Importers`, secrets `ACUMATICA_USERNAME` / `ACUMATICA_PASSWORD`), logout in `finally`. REST values are `{ "value": x }`. The function also has a `{"probe":"<ref>"}` mode (raw JSON, stores nothing).

| Contract field | Source (entity.field) |
|---|---|
| ref, date, due_date, status | Invoice.ReferenceNbr, Date, DueDate, Status (filter `Type eq 'Invoice'`; status is `Open` for 1059165) |
| customer_id | Invoice.Customer |
| customer_name, bill name fallback | Customer.CustomerName (SalesInvoice.BillToContact is null when it inherits the customer's) |
| currency | SalesInvoice.Currency (not on Invoice) |
| terms | Invoice.Terms is the ID (`30DAYS`); REST has no Terms entity, so the description is derived: `N DAYS` becomes "Due in N Days", other IDs print as-is. Add a mapping if a term needs different text |
| sales_total / discount_total | SalesInvoice.DetailTotal / DiscountTotal (not on Invoice) |
| tax_total / total | Invoice.TaxTotal / Amount |
| last_modified | Invoice.LastModifiedDateTime (change pickup: `LastModifiedDateTime gt datetimeoffset'...'`) |
| bill / ship | SalesInvoice.BillToAddress / ShipToAddress (AddressLine1/2, City, State, PostalCode, Country) and ShipToContact.BusinessName, all expanded |
| so_number, shipment_nbr | SalesInvoice.Details[].OrderNbr / ShipmentNbr (first line that has them) |
| ship_via | Shipment.ShipVia for that shipment number (here KLOVELACETRK02) |
| salesperson | SalesOrder.Details[].SalespersonID, first line with one (no header field), here KC |
| customer_po, customer_ref | SalesOrder.CustomerOrder, ExternalRef (empty on this order) |
| lines | Invoice.Details[]: LineNbr, InventoryID, TransactionDescription, Qty, UOM, UnitPrice, ExtendedPrice, DiscountAmount, TaxCategory (TAXABLE / NONTAXABLE) |
| note | always null (not printed) |

Result for 1059165: Sales 114,710.60, Discount 0, Tax 17,206.60, Total 131,917.20, three TAXABLE lines (44,560.00 + 45,237.30 + 24,913.30); 15% of each rounded line sums to 17,206.60 = TaxTotal. Bill-to and ship-to BRAVO SUPERMARKET (no Friday delivery), 5 BRAVO STREET, ST. ANNS BAY, Jamaica; SO 208825; shipment 282168. City and postal code are empty for this customer. `discount_total` is the document-level discount; line discounts are in `DiscountAmount`.
