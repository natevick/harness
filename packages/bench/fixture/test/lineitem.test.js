import test from 'node:test';
import assert from 'node:assert/strict';
import { lineTotal } from '../src/lineitem.js';

test('lineTotal multiplies unit price by quantity', () => {
  assert.equal(lineTotal({ unitPriceCents: 500, quantity: 2 }), 1000);
  assert.equal(lineTotal({ unitPriceCents: 1, quantity: 7 }), 7);
});

test('lineTotal discounts the line total, not each unit', () => {
  assert.equal(lineTotal({ unitPriceCents: 333, quantity: 3, discountRate: 0.1 }), 899);
  assert.equal(lineTotal({ unitPriceCents: 105, quantity: 4, discountRate: 0.5 }), 210);
  assert.equal(lineTotal({ unitPriceCents: 999, quantity: 5, discountRate: 0.2 }), 3996);
});

test('lineTotal validates its input', () => {
  assert.throws(() => lineTotal({ unitPriceCents: 10.5, quantity: 1 }), TypeError);
  assert.throws(() => lineTotal({ unitPriceCents: 100, quantity: 0 }), RangeError);
  assert.throws(() => lineTotal({ unitPriceCents: 100, quantity: 1.5 }), RangeError);
  assert.throws(() => lineTotal({ unitPriceCents: 100, quantity: 1, discountRate: 1.2 }), RangeError);
});
