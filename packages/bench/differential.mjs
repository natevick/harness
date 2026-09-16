// Differential check: exercise each seat's fix on inputs the test suite never
// covers, and compare against the reference solution. A seat that passes 39/39
// but diverges here was fitting the tests, not fixing the defect.
//
// usage: node differential.mjs <dir> [<dir> ...]
import path from 'node:path';

const CASES = [];
const add = (label, fn) => CASES.push({ label, fn });

// toCents — third-decimal ties and float-dust values absent from the suite
for (const v of ['0.015', '0.025', '0.035', '-0.015', '0.005', '-0.005', '3.456',
                 '0.999', '12.345', '8.165', '1.115', '99.995', '0', '-0.001']) {
  add(`toCents(${JSON.stringify(v)})`, (m) => m.money.toCents(v));
}
for (const v of [1.005, 2.675, 0.07, 8.165, 1.115, -1.005, 0.1, 1e-4]) {
  add(`toCents(${v})`, (m) => m.money.toCents(v));
}

// mulCents — negative ties and sub-cent products
for (const [c, r] of [[-3, 0.5], [3, 0.5], [-5, 0.5], [7, 0.5], [-7, 0.5],
                      [-1, 0.005], [1, 0.005], [-999, 0.1], [-333, 0.1],
                      [12345, 0.075], [-12345, 0.075], [0, 0.5], [-2, 0.25]]) {
  add(`mulCents(${c}, ${r})`, (m) => m.money.mulCents(c, r));
}

// formatCents — small negatives and boundaries
for (const c of [-1, 99, -99, 1, -1234567, 100000, -100000, 9]) {
  add(`formatCents(${c})`, (m) => m.currency.formatCents(c));
}

// applyDiscounts — orderings and stacks the suite does not use
add('applyDiscounts(9999,[f100,p0.33,f1,p0.01])', (m) =>
  m.discount.applyDiscounts(9999, [
    { type: 'fixed', amountCents: 100 },
    { type: 'percent', rate: 0.33 },
    { type: 'fixed', amountCents: 1 },
    { type: 'percent', rate: 0.01 },
  ]));
add('applyDiscounts(1,[p0.5])', (m) =>
  m.discount.applyDiscounts(1, [{ type: 'percent', rate: 0.5 }]));
add('applyDiscounts(0,[f1])', (m) =>
  m.discount.applyDiscounts(0, [{ type: 'fixed', amountCents: 1 }]));

// computeTax — compound rule FIRST (suite only ever puts it second)
add('computeTax(10000,[compound,plain])', (m) =>
  m.tax.computeTax(10000, [
    { name: 'a', rate: 0.1, compound: true },
    { name: 'b', rate: 0.1, compound: false },
  ]).totalCents);
add('computeTax(7777,[3x compound])', (m) =>
  m.tax.computeTax(7777, [
    { name: 'a', rate: 0.07, compound: true },
    { name: 'b', rate: 0.03, compound: true },
    { name: 'c', rate: 0.02, compound: true },
  ]).totalCents);

// isCouponValid — one-ms-inside boundaries and equal from/expiry
add('coupon at expiry-1ms', (m) => m.coupon.isCouponValid(
  { validFrom: '2026-03-01T00:00:00Z', expiresAt: '2026-03-31T23:59:59Z', usageCount: 0, maxUses: 5 },
  '2026-03-31T23:59:58.999Z'));
add('coupon validFrom===expiresAt', (m) => m.coupon.isCouponValid(
  { validFrom: '2026-03-01T00:00:00Z', expiresAt: '2026-03-01T00:00:00Z', usageCount: 0, maxUses: 1 },
  '2026-03-01T00:00:00Z'));
add('coupon maxUses 0', (m) => m.coupon.isCouponValid(
  { validFrom: '2026-03-01T00:00:00Z', expiresAt: '2026-03-31T00:00:00Z', usageCount: 0, maxUses: 0 },
  '2026-03-15T00:00:00Z'));

// prorate — 28/29/31-day periods and mid-day changes the suite never uses
add('prorate Feb 2026 (28d) mid', (m) =>
  m.proration.prorate(2800, '2026-02-01T00:00:00Z', '2026-03-01T00:00:00Z', '2026-02-15T00:00:00Z'));
add('prorate leap Feb 2028 (29d)', (m) =>
  m.proration.prorate(2900, '2028-02-01T00:00:00Z', '2028-03-01T00:00:00Z', '2028-02-15T00:00:00Z'));
add('prorate half-day change', (m) =>
  m.proration.prorate(3100, '2026-01-01T00:00:00Z', '2026-02-01T00:00:00Z', '2026-01-16T12:00:00Z'));
add('prorate DST-spanning US month', (m) =>
  m.proration.prorate(3100, '2026-03-01T00:00:00Z', '2026-04-01T00:00:00Z', '2026-03-15T00:00:00Z'));

// buildInvoice — compound tax + coupon + line discount together
add('buildInvoice combined', (m) => JSON.stringify(m.invoice.buildInvoice({
  lines: [
    { unitPriceCents: 1999, quantity: 3, discountRate: 0.15 },
    { unitPriceCents: 105, quantity: 4, discountRate: 0.5 },
  ],
  discounts: [{ type: 'fixed', amountCents: 250 }, { type: 'percent', rate: 0.05 }],
  coupons: [{
    validFrom: '2026-01-01T00:00:00Z', expiresAt: '2026-06-01T00:00:00Z',
    usageCount: 2, maxUses: 5, discount: { type: 'percent', rate: 0.1 },
  }],
  taxRules: [
    { name: 'GST', rate: 0.05, compound: false },
    { name: 'QST', rate: 0.09975, compound: true },
  ],
  asOf: '2026-03-15T00:00:00Z',
})));

async function load(dir) {
  const abs = path.resolve(dir);
  const mods = {};
  for (const name of ['money', 'currency', 'discount', 'tax', 'coupon', 'proration', 'invoice', 'lineitem']) {
    mods[name] = await import(`file://${abs}/src/${name}.js`);
  }
  return mods;
}

function evaluate(mods) {
  return CASES.map(({ fn }) => {
    try {
      const v = fn(mods);
      // Distinguish -0 from 0 so a sign-normalisation difference is visible.
      return Object.is(v, -0) ? '-0' : String(v);
    } catch (err) {
      return `throws:${err.constructor.name}`;
    }
  });
}

const dirs = process.argv.slice(2);
const results = {};
for (const d of dirs) results[path.basename(d)] = evaluate(await load(d));

const names = Object.keys(results);
const ref = names[0];
let diffs = 0;
console.log(`reference = ${ref}\n`);
CASES.forEach(({ label }, i) => {
  const base = results[ref][i];
  const off = names.slice(1).filter((n) => results[n][i] !== base);
  if (off.length) {
    diffs += 1;
    console.log(`DIFF  ${label}`);
    console.log(`      ${ref} => ${base}`);
    for (const n of off) console.log(`      ${n} => ${results[n][i]}`);
  }
});
console.log(`\n${CASES.length} cases, ${diffs} divergent`);
for (const n of names.slice(1)) {
  const bad = CASES.filter((_, i) => results[n][i] !== results[ref][i]).length;
  console.log(`  ${n}: ${CASES.length - bad}/${CASES.length} agree with reference`);
}
