import test from 'node:test';
import assert from 'node:assert/strict';
import { assertCents, mulCents, sumCents, toCents } from '../src/money.js';

test('toCents handles plain two-decimal amounts', () => {
  assert.equal(toCents('19.99'), 1999);
  assert.equal(toCents('0.07'), 7);
  assert.equal(toCents('100'), 10000);
  assert.equal(toCents(0.07), 7);
});

test('toCents rounds a third decimal half away from zero', () => {
  assert.equal(toCents('1.005'), 101);
  assert.equal(toCents('2.675'), 268);
  assert.equal(toCents('-1.005'), -101);
  assert.equal(toCents('0.004'), 0);
});

test('toCents rejects amounts that are not finite numbers', () => {
  assert.throws(() => toCents('abc'), TypeError);
  assert.throws(() => toCents(Infinity), TypeError);
});

test('mulCents rounds ties away from zero', () => {
  assert.equal(mulCents(101, 0.5), 51);
  assert.equal(mulCents(-101, 0.5), -51);
  assert.equal(mulCents(1, 0.5), 1);
  assert.equal(mulCents(-1, 0.5), -1);
});

test('mulCents rounds non-ties to the nearest cent', () => {
  assert.equal(mulCents(999, 0.1), 100);
  assert.equal(mulCents(333, 0.1), 33);
  assert.equal(mulCents(10000, 0), 0);
});

test('mulCents rejects non-integer cents', () => {
  assert.throws(() => mulCents(10.5, 1), TypeError);
});

test('sumCents adds and validates', () => {
  assert.equal(sumCents([1, 2, 3]), 6);
  assert.equal(sumCents([]), 0);
  assert.throws(() => sumCents([1, 2.5]), TypeError);
});

test('assertCents returns its input', () => {
  assert.equal(assertCents(42), 42);
});
