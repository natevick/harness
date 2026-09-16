import test from 'node:test';
import assert from 'node:assert/strict';
import { applyDiscounts } from '../src/discount.js';

test('percent discounts run before fixed ones whatever order they arrive in', () => {
  assert.equal(
    applyDiscounts(10000, [
      { type: 'fixed', amountCents: 500 },
      { type: 'percent', rate: 0.1 },
    ]),
    8500,
  );
  assert.equal(
    applyDiscounts(10000, [
      { type: 'percent', rate: 0.1 },
      { type: 'fixed', amountCents: 500 },
    ]),
    8500,
  );
});

test('percent discounts do not compound with each other', () => {
  assert.equal(
    applyDiscounts(10000, [
      { type: 'percent', rate: 0.1 },
      { type: 'percent', rate: 0.1 },
    ]),
    8000,
  );
});

test('the discounted total is floored at zero', () => {
  assert.equal(applyDiscounts(10000, [{ type: 'fixed', amountCents: 15000 }]), 0);
  assert.equal(
    applyDiscounts(10000, [
      { type: 'percent', rate: 1 },
      { type: 'fixed', amountCents: 250 },
    ]),
    0,
  );
});

test('an empty discount list is a no-op', () => {
  assert.equal(applyDiscounts(10000), 10000);
  assert.equal(applyDiscounts(10000, []), 10000);
});

test('unknown discount types are rejected', () => {
  assert.throws(() => applyDiscounts(10000, [{ type: 'bogus' }]), /unknown discount type/);
});
