/* DFL tax invoice renderer (Acumatica report SO643000 look-alike) on US Letter.
 *
 *   InvoicePrint.check(inv)        -> { ok, problems[] }   tax / totals guard; refuse to print when not ok
 *   InvoicePrint.pages(inv, opts)  -> [html, ...]          one string per 8.5in x 11in sheet
 *   InvoicePrint.show(pages)       -> adds body.printing, fills #printWrap, calls window.print()
 *
 * opts.reprint = { n: 2 }   marks every sheet REPRINT 2 (header tag + diagonal watermark). First prints pass no reprint.
 * opts.slip = true          DELIVERY SLIP instead of a tax invoice: same layout, no prices, tax or totals (donation / promotion orders)
 * opts.logo              logo URL, default 'assets/dfl-logo-color.png' (relative to the host page)
 *
 * Host page contract (same pattern as invoicing.html):
 *   <div id="printWrap" aria-hidden="true"></div>   direct child of <body>, hidden on screen by the host (display:none)
 *   InvoicePrint.show(pages) fills it, sets body.printing and prints. On afterprint it clears both.
 *   Print CSS here hides everything except #printWrap while body.printing is set and sets @page to letter, margin 0.
 *   If the host has its own @page rule (invoicing.html uses 9.5in x 11in for the dot matrix), the host must not
 *   apply it while printing these sheets, or the sheets will be scaled/cropped.
 *
 * Layout is deterministic: monospace type, descriptions wrapped by character count, every block a fixed height,
 * so the line budget per page is computed rather than measured from the DOM.
 */
(function () {
  'use strict';

  // ---- constants ----
  const GCT = 0.15;
  const TOL = 0.05;
  // Tax categories: the stock item's category is TAXABLE or NONTAXABLE; the sample form shows TX. Accept both.
  const TAXABLE_CATS = ['TX', 'TAXABLE'];
  const TAXABLE = 'TX';
  const isTaxable = cat => TAXABLE_CATS.includes(String(cat || '').toUpperCase());
  const taxLabel = cat => isTaxable(cat) ? 'TX' : /^NON/i.test(String(cat || '')) ? 'NT' : String(cat || '');
  const COMPANY = ['Decasseres Farm Limited', '71 Molynes Rd', 'Kingston 10', 'Phone: 1-876-622-6718'];
  const GCT_REF = 'GCT Ref # 000-439-363';
  const DISCLAIMER = 'Damaged goods returned after 45 days will not be accepted by DFL. Returned cheques attract a fee of 1% of the total value returned.';

  // page geometry in pt (Letter = 612 x 792). Every block has a fixed height so the body budget is exact.
  const LH = 11;                 // line height
  const ROW_GAP = 3;             // space under each invoice line
  const ITEM_WRAP = 60;          // chars per line in the ITEM column
  const NOTE_WRAP = 70;          // chars per line for a line note
  const TOP_USED = 306;          // everything above the first line row
  const BOTTOM_MORE = 40;        // continued/page row + bottom margin, non-last pages
  const BOTTOM_LAST = 26 + 14 + 108 + 4;   // margin + page row + footer block + gap, last page
  const BODY_MORE = 792 - TOP_USED - BOTTOM_MORE;
  const BODY_LAST = 792 - TOP_USED - BOTTOM_LAST;

  // ---- helpers ----
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const cents = n => Math.round((Number(n) || 0) * 100);
  const money = n => (Number(n) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function niceDate(d) {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || ''));
    return m ? `${m[3]}-${MON[+m[2] - 1]}-${m[1]}` : '';
  }

  // Tax for one line: 15% of the amount, rounded half up to the cent (integer arithmetic, no float drift).
  const lineTaxCents = amount => Math.floor((cents(amount) * 15 + 50) / 100);

  // ---- tax guard ----
  function check(inv) {
    const problems = [];
    const lines = (inv && inv.lines) || [];
    if (!inv) return { ok: false, problems: ['No invoice data'] };
    if (!lines.length) problems.push('Invoice has no lines');
    let sum = 0, disc = 0, tax = 0;
    lines.forEach(l => {
      sum += cents(l.amount);
      disc += cents(l.discount);
      if (isTaxable(l.tax_cat)) tax += lineTaxCents(l.amount);
    });
    const near = (a, b) => Math.abs(a - b) <= TOL * 100 + 1e-6;
    // Acumatica taxes the base net of a document-level discount (spread pro rata over the lines), so accept that too.
    let taxNet = tax;
    const dd = cents(inv.discount_total);
    if (dd > 0 && sum > 0) {
      let base = 0;
      lines.forEach(l => { if (isTaxable(l.tax_cat)) base += cents(l.amount); });
      taxNet = Math.round((base - base * dd / sum) * 15 / 100);
    }
    if (!near(tax, cents(inv.tax_total)) && !near(taxNet, cents(inv.tax_total)))
      problems.push(`Tax does not reconcile: ${money(tax / 100)} at ${GCT * 100}% on lines tagged ${TAXABLE}, invoice says ${money(inv.tax_total)}`);
    // Line amounts may or may not already be net of line discounts, so accept either reading.
    if (!near(sum, cents(inv.sales_total)) && !near(sum - disc, cents(inv.sales_total)))
      problems.push(`Lines do not add up to Sales: lines ${money(sum / 100)}, invoice says ${money(inv.sales_total)}`);
    const t = cents(inv.sales_total) + cents(inv.tax_total);
    if (!near(t, cents(inv.total)) && !near(t - cents(inv.discount_total), cents(inv.total)))
      problems.push(`Total does not equal Sales + Tax (less discount): expected ${money(t / 100)}, invoice says ${money(inv.total)}`);
    return { ok: !problems.length, problems };
  }

  // ---- wrapping ----
  // Word wrap to w chars; a word longer than w is split.
  function wrap(text, w) {
    const out = [];
    String(text == null ? '' : text).split(/\r?\n/).forEach(par => {
      let cur = '';
      par.split(/\s+/).filter(Boolean).forEach(word => {
        while (word.length > w) {
          if (cur) { out.push(cur); cur = ''; }
          out.push(word.slice(0, w)); word = word.slice(w);
        }
        if (!cur) cur = word;
        else if (cur.length + 1 + word.length <= w) cur += ' ' + word;
        else { out.push(cur); cur = word; }
      });
      out.push(cur);
    });
    return out;
  }

  function prepLine(l) {
    const itemTxt = (l.item ? l.item + ': ' : '') + (l.descr || '');
    const item = wrap(itemTxt, ITEM_WRAP);
    const note = l.note && String(l.note).trim() ? wrap(l.note, NOTE_WRAP) : [];
    return { l, item, note, h: (item.length + note.length) * LH + ROW_GAP };
  }

  // Greedy fill at the non-last budget, then make sure the last sheet also fits beside the footer block.
  function paginate(rows) {
    const pages = [[]];
    let used = 0;
    rows.forEach(r => {
      if (used + r.h > BODY_MORE && pages[pages.length - 1].length) { pages.push([]); used = 0; }
      pages[pages.length - 1].push(r); used += r.h;
    });
    const hOf = p => p.reduce((t, r) => t + r.h, 0);
    let last = pages[pages.length - 1];
    if (hOf(last) > BODY_LAST) {
      const spill = [];
      while (last.length > 1 && hOf(last) > BODY_LAST) spill.unshift(last.pop());
      if (hOf(last) > BODY_LAST) { spill.unshift(last.pop()); }
      pages.push(spill);
    }
    return pages;
  }

  // ---- CSS (injected once) ----
  const CSS = `
.ip-sheet { position:relative; width:8.5in; height:11in; box-sizing:border-box; overflow:hidden; background:#fff; color:#000; font:8.5pt/${LH}pt 'Courier New',Courier,monospace; break-after:page; page-break-after:always; }
.ip-sheet:last-child { break-after:auto; page-break-after:auto; }
.ip-sheet * { box-sizing:border-box; }
.ip-wm { position:absolute; left:0; top:0; width:100%; height:100%; overflow:hidden; display:flex; flex-wrap:wrap; align-content:flex-start; gap:64pt 46pt; padding:20pt 14pt; opacity:.045; pointer-events:none; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
.ip-wm span { display:block; }
.ip-wm img { height:40pt; display:block; }
.ip-rwm { position:absolute; left:0; right:0; top:4.3in; text-align:center; transform:rotate(-30deg); font:700 96pt/1 Arial,sans-serif; color:rgba(0,0,0,.11); pointer-events:none; white-space:nowrap; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
.ip-in { position:absolute; left:.4in; right:.4in; top:30pt; bottom:0; }
.ip-head { display:flex; justify-content:space-between; height:104pt; }
.ip-co img { height:48pt; display:block; margin-bottom:4pt; }
.ip-co div { font-weight:400; }
.ip-hr { width:3.5in; }
.ip-title { border:1pt solid #000; text-align:center; padding:3pt 0; height:32pt; position:relative; }
.ip-title b { display:block; font:700 13pt/15pt 'Courier New',Courier,monospace; }
.ip-rp { position:absolute; right:4pt; top:3pt; padding:0 4pt; border:1.2pt solid #000; font-weight:700; }
.ip-meta { margin-top:0; }
.ip-meta div { display:flex; height:13pt; line-height:12pt; border:1pt solid #000; border-top:0; }
.ip-meta span:first-child { flex:1; padding-left:4pt; }
.ip-meta span:last-child { width:58%; border-left:1pt solid #000; padding-right:4pt; text-align:right; }
.ip-addr { display:flex; gap:10pt; height:84pt; margin-top:6pt; }
.ip-box { flex:1; border:1pt solid #000; padding:3pt 5pt; overflow:hidden; }
.ip-box h6 { margin:0 0 2pt; font:400 8.5pt/${LH}pt 'Courier New',Courier,monospace; }
.ip-ref { display:grid; height:24pt; margin-top:6pt; border:1pt solid #000; }
.ip-ref.a { grid-template-columns:1.1fr 1.4fr 1.5fr; }
.ip-sl .ip-ref.a { grid-template-columns:1fr 1fr; }
.ip-ref.b { grid-template-columns:1fr 1.2fr 1.2fr 1.4fr; margin-top:4pt; }
.ip-ref div { padding:1pt 5pt; border-left:1pt solid #000; overflow:hidden; white-space:nowrap; }
.ip-ref div:first-child { border-left:0; }
.ip-ref i { display:block; font-style:normal; font-weight:400; font-size:7pt; line-height:9pt; }
.ip-th, .ip-row { display:grid; grid-template-columns:4ch 62ch 8ch 5ch 12ch 5ch 1fr; }
.ip-sl .ip-th, .ip-sl .ip-row { grid-template-columns:4ch 1fr 8ch 8ch; }
.ip-th { margin-top:8pt; height:16pt; line-height:14pt; font-weight:400; border:1pt solid #000; }
.ip-th > div + div { border-left:1pt solid #000; }
.ip-th > div, .ip-row > div { padding:0 2pt; }
.ip-th .r, .ip-row .r { text-align:right; }
.ip-th .c, .ip-row .c { text-align:center; }
.ip-body { overflow:hidden; }
.ip-row { white-space:pre; margin-bottom:${ROW_GAP}pt; }
.ip-note { white-space:pre; padding-left:4ch; margin-bottom:0; }
.ip-pg { position:absolute; left:0; right:0; bottom:26pt; height:14pt; display:flex; justify-content:space-between; }
.ip-foot { position:absolute; left:0; right:0; bottom:44pt; height:108pt; display:flex; gap:14pt; border-top:1pt solid #000; padding-top:4pt; }
.ip-fl { flex:1; }
.ip-fl p { margin:0 0 4pt; }
.ip-sig { white-space:nowrap; }
.ip-tot { width:2in; border:1pt solid #000; align-self:flex-start; }
.ip-tot div { display:flex; justify-content:space-between; padding:0 6pt; height:15pt; line-height:15pt; border-top:1pt solid #000; }
.ip-tot div:first-child { border-top:0; }

@media print {
  @page { size:letter; margin:0; }
  body.printing { background:#fff; }
  body.printing > *:not(#printWrap) { display:none !important; }
  body.printing #printWrap { display:block; }
  .ip-sheet { box-shadow:none !important; margin:0 !important; border:0 !important; }
}`;

  function injectCss() {
    if (document.getElementById('ip-css')) return;
    const s = document.createElement('style');
    s.id = 'ip-css';
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  // ---- sheet pieces ----
  const addrBox = (title, a) => {
    a = a || {};
    return `<div class="ip-box"><h6>${title}</h6>${[a.name].concat(a.lines || []).filter(Boolean).map(t => `<div>${esc(t)}</div>`).join('')}</div>`;
  };
  const refCell = (label, val) => `<div><i>${label}</i>${esc(val)}</div>`;

  function watermark(logo) {
    const one = `<span><img src="${esc(logo)}" alt=""></span>`;
    return `<div class="ip-wm">${one.repeat(48)}</div>`;
  }

  function sheet(inv, rows, pg, npages, opts) {
    const last = pg === npages - 1;
    const rp = opts.reprint && opts.reprint.n ? opts.reprint.n : 0;
    const cur = inv.currency || 'JMD';
    const slip = !!opts.slip;
    const body = rows.map(r => {
      const l = r.l;
      if (slip) return `<div class="ip-row"><div>${esc(l.n)}</div><div>${r.item.map(esc).join('\n')}</div><div class="r">${money(l.qty)}</div><div class="u">${esc(l.uom)}</div></div>`
        + (r.note.length ? `<div class="ip-row ip-note" style="display:block;margin-bottom:${ROW_GAP}pt">${r.note.map(esc).join('\n')}</div>` : '');
      return `<div class="ip-row"><div>${esc(l.n)}</div><div>${r.item.map(esc).join('\n')}</div><div class="r">${money(l.qty)}</div><div class="u">${esc(l.uom)}</div><div class="r">${money(l.unit_price)}</div><div class="c">${esc(taxLabel(l.tax_cat))}</div><div class="r">${money(l.amount)}</div></div>`
        + (r.note.length ? `<div class="ip-row ip-note" style="display:block;margin-bottom:${ROW_GAP}pt">${r.note.map(esc).join('\n')}</div>` : '');
    }).join('');
    const foot = last ? `<div class="ip-foot"><div class="ip-fl"><p>${esc(DISCLAIMER)}</p><p>RECEIVED IN GOOD CONDITION BY:</p><div class="ip-sig">CUSTOMER NAME:_____________ SIGNATURE:_________________</div><div class="ip-sig" style="margin-top:4pt">TRUCKER NAME: ________________ SIGNATURE:____________________</div></div>`
      + (slip ? '</div>' : `<div class="ip-tot"><div><span>Sales</span><span>${money(inv.sales_total)}</span></div><div><span>Discount:</span><span>${money(inv.discount_total)}</span></div><div><span>Tax Total:</span><span>${money(inv.tax_total)}</span></div><div><span>Total</span><span>${money(inv.total)}</span></div></div></div>`) : '';
    return `<div class="ip-sheet${slip ? ' ip-sl' : ''}">${watermark(opts.logo)}${rp ? `<div class="ip-rwm">REPRINT ${rp}</div>` : ''}<div class="ip-in">`
      + `<div class="ip-head"><div class="ip-co"><img src="${esc(opts.logo)}" alt="DFL">${COMPANY.map(t => `<div>${esc(t)}</div>`).join('')}</div>`
      + `<div class="ip-hr"><div class="ip-title"><b>${slip ? 'DELIVERY SLIP' : 'TAX INVOICE'}</b>${slip ? '' : esc(GCT_REF)}${rp ? `<span class="ip-rp">REPRINT ${rp}</span>` : ''}</div>`
      + `<div class="ip-meta"><div><span>${slip ? 'Invoice Ref.:' : 'Invoice No.:'}</span><span>${esc(inv.ref)}</span></div><div><span>Date:</span><span>${esc(niceDate(inv.date))}</span></div>${slip ? '' : `<div><span>Due Date:</span><span>${esc(niceDate(inv.due_date))}</span></div>`}<div><span>Customer ID:</span><span>${esc(inv.customer_id)}</span></div><div><span>Currency:</span><span>${esc(cur)}</span></div></div></div></div>`
      + `<div class="ip-addr">${addrBox('BILL TO:', inv.bill)}${addrBox('SHIP TO:', inv.ship)}</div>`
      + `<div class="ip-ref a">${refCell('CUSTOMER REF. NUMBER', inv.customer_ref)}${slip ? '' : refCell('TERMS', inv.terms)}${refCell('CONTACT', inv.salesperson)}</div>`
      + `<div class="ip-ref b">${refCell('SHIP VIA', inv.ship_via)}${refCell('SO NUMBER', inv.so_number)}${refCell('SHIPMENT NUMBER', inv.shipment_nbr)}${refCell('CUSTOMER P.O. NO.', inv.customer_po)}</div>`
      + `<div class="ip-th"><div>NO.</div><div>ITEM</div><div class="r">QTY.</div><div class="u">UOM</div>${slip ? '' : '<div class="r">UNIT PRICE</div><div class="c">TAX</div><div class="r">EXTENDED</div>'}</div>`
      + `<div class="ip-body" style="height:${last ? BODY_LAST : BODY_MORE}pt">${body}</div>`
      + foot
      + `<div class="ip-pg"><span>${last ? '' : 'Continued...'}</span><span>Page: ${pg + 1} of ${npages}</span></div></div></div>`;
  }

  function pages(inv, opts) {
    opts = Object.assign({ logo: 'assets/dfl-logo-color.png' }, opts || {});
    injectCss();
    try { new Image().src = opts.logo; } catch (e) {}
    const sets = paginate((inv.lines || []).map(prepLine));
    return sets.map((rows, i) => sheet(inv, rows, i, sets.length, opts));
  }

  // Fill #printWrap, switch the page to print mode, print, then restore. Same flow as invoicing.html's showSheets.
  function show(pgs) {
    injectCss();
    const w = document.getElementById('printWrap');
    w.innerHTML = pgs.join('');
    document.body.classList.add('printing');
    const done = () => { document.body.classList.remove('printing'); w.innerHTML = ''; window.removeEventListener('afterprint', done); };
    window.addEventListener('afterprint', done);
    // Print only once the logo / watermark images have loaded (they are the same file, so this is quick). Printing
    // straight away can send the sheets to the printer with no logo and no watermark. 5s cap so a missing image
    // never blocks the print.
    const waits = Array.from(new Set(Array.from(w.querySelectorAll('img')).map(i => i.src))).map(src => new Promise(res => {
      const im = new Image();
      im.onload = im.onerror = () => res();
      im.src = src;
      if (im.complete) res();
    }));
    const imgs = Array.from(w.querySelectorAll('img')).map(i => (i.decode ? i.decode().catch(() => {}) : null));
    Promise.race([Promise.all(waits.concat(imgs)), new Promise(res => setTimeout(res, 5000))]).then(() => window.print());
  }

  window.InvoicePrint = { check, pages, show, niceDate };
})();
