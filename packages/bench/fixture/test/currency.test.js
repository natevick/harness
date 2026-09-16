import test from 'node:test';
import assert from 'node:assert/strict';
import { formatCents } from '../src/currency.js';

test('formatCents always renders exactly two fractional digits', () => {
  assert.equal(formatCents(5), '$0.05');
  assert.equal(formatCents(1000), '$10.00');
  assert.equal(formatCents(1999), '$19.99');
  assert.equal(formatCents(0), '$0.00');
});

test('formatCents renders negatives with a single leading minus', () => {
  assert.equal(formatCents(-100), '-$1.00');
  assert.equal(formatCents(-5), '-$0.05');
});

test('formatCents picks the symbol and emits no thousands separators', () => {
  assert.equal(formatCents(120, 'EUR'), '€1.20');
  assert.equal(formatCents(1234567), '$12345.67');
  assert.equal(formatCents(100, 'ZZZ'), '$1.00');
});
