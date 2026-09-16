import test from 'node:test';
import assert from 'node:assert/strict';
import { buildInvoice } from '../src/invoice.js';

test('tax is charged on the discounted amount, not the subtotal', () => {
  const inv = buildInvoice({
    lines: [{ unitPriceCents: 2500, quantity: 4 }],
    discounts: [
      { type: 'fixed', amountCents: 500 },
      { type: 'percent', rate: 0.1 },
    ],
    taxRules: [
      { name: 'GST', rate: 0.05, compound: false },
      { name: 'QST', rate: 0.09975, compound: true },
    ],
    asOf: '2026-03-15T00:00:00Z',
  });
  assert.equal(inv.subtotalCents, 10000);
  assert.equal(inv.discountCents, 1500);
  assert.equal(inv.taxCents, 1315);
  assert.equal(inv.totalCents, 9815);
});

test('a coupon expiring at this very instant still applies', () => {
  const inv = buildInvoice({
    lines: [{ unitPriceCents: 1000, quantity: 1 }],
    coupons: [
      {
        validFrom: '2026-03-01T00:00:00Z',
        expiresAt: '2026-03-15T00:00:00Z',
        usageCount: 0,
        maxUses: 1,
        discount: { type: 'percent', rate: 0.2 },
      },
    ],
    taxRules: [{ name: 'VAT', rate: 0.2 }],
    asOf: '2026-03-15T00:00:00Z',
  });
  assert.equal(inv.discountCents, 200);
  assert.equal(inv.taxCents, 160);
  assert.equal(inv.totalCents, 960);
});

test('a coupon that expired a millisecond ago does not apply', () => {
  const inv = buildInvoice({
    lines: [{ unitPriceCents: 1000, quantity: 1 }],
    coupons: [
      {
        validFrom: '2026-03-01T00:00:00Z',
        expiresAt: '2026-03-15T00:00:00Z',
        usageCount: 0,
        maxUses: 1,
        discount: { type: 'percent', rate: 0.2 },
      },
    ],
    taxRules: [{ name: 'VAT', rate: 0.2 }],
    asOf: '2026-03-15T00:00:00.001Z',
  });
  assert.equal(inv.discountCents, 0);
  assert.equal(inv.taxCents, 200);
  assert.equal(inv.totalCents, 1200);
});

test('an over-discounted invoice settles at zero', () => {
  const inv = buildInvoice({
    lines: [{ unitPriceCents: 5000, quantity: 2 }],
    discounts: [{ type: 'fixed', amountCents: 20000 }],
    taxRules: [{ name: 'VAT', rate: 0.2 }],
    asOf: '2026-03-15T00:00:00Z',
  });
  assert.equal(inv.discountCents, 10000);
  assert.equal(inv.taxCents, 0);
  assert.equal(inv.totalCents, 0);
});

test('line-level and invoice-level discounts combine', () => {
  const inv = buildInvoice({
    lines: [
      { unitPriceCents: 333, quantity: 3, discountRate: 0.1 },
      { unitPriceCents: 999, quantity: 5, discountRate: 0.2 },
    ],
    discounts: [{ type: 'percent', rate: 0.5 }],
    asOf: '2026-03-15T00:00:00Z',
  });
  assert.equal(inv.subtotalCents, 4895);
  assert.equal(inv.totalCents, 2447);
});

test('an invoice needs at least one line', () => {
  assert.throws(() => buildInvoice({ lines: [], asOf: '2026-03-15T00:00:00Z' }), RangeError);
});
