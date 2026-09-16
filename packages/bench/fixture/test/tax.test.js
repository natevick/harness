import test from 'node:test';
import assert from 'node:assert/strict';
import { computeTax } from '../src/tax.js';

test('non-compound rules all charge the same base', () => {
  const { lines, totalCents } = computeTax(10000, [
    { name: 'state', rate: 0.06, compound: false },
    { name: 'city', rate: 0.02, compound: false },
  ]);
  assert.deepEqual(lines, [
    { name: 'state', cents: 600 },
    { name: 'city', cents: 200 },
  ]);
  assert.equal(totalCents, 800);
});

test('a compound rule charges the base plus the tax ahead of it', () => {
  const { lines, totalCents } = computeTax(10000, [
    { name: 'GST', rate: 0.05, compound: false },
    { name: 'QST', rate: 0.09975, compound: true },
  ]);
  assert.deepEqual(lines, [
    { name: 'GST', cents: 500 },
    { name: 'QST', cents: 1047 },
  ]);
  assert.equal(totalCents, 1547);
});

test('compound rules stack in the order given', () => {
  const { totalCents } = computeTax(10000, [
    { name: 'a', rate: 0.1, compound: false },
    { name: 'b', rate: 0.1, compound: true },
    { name: 'c', rate: 0.1, compound: true },
  ]);
  assert.equal(totalCents, 3310);
});

test('a missing compound flag means non-compound', () => {
  const { totalCents } = computeTax(10000, [{ name: 'flat', rate: 0.07 }]);
  assert.equal(totalCents, 700);
});

test('no rules means no tax', () => {
  assert.deepEqual(computeTax(10000), { lines: [], totalCents: 0 });
});
