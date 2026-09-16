import test from 'node:test';
import assert from 'node:assert/strict';
import { prorate } from '../src/proration.js';

const JAN = '2026-01-01T00:00:00Z';
const FEB = '2026-02-01T00:00:00Z';

test('a January period is 31 days, not 32', () => {
  assert.equal(prorate(3100, JAN, FEB, '2026-01-16T00:00:00Z'), 1600);
});

test('a change at the period start prorates to the full amount', () => {
  assert.equal(prorate(3100, JAN, FEB, JAN), 3100);
});

test('a change at the period end prorates to nothing', () => {
  assert.equal(prorate(3100, JAN, FEB, FEB), 0);
});

test('a 30-day period divides by 30', () => {
  assert.equal(
    prorate(6000, '2026-04-01T00:00:00Z', '2026-05-01T00:00:00Z', '2026-04-21T00:00:00Z'),
    2000,
  );
});

test('proration rejects an impossible period or instant', () => {
  assert.throws(() => prorate(3100, FEB, JAN, JAN), RangeError);
  assert.throws(() => prorate(3100, JAN, FEB, '2026-03-01T00:00:00Z'), RangeError);
  assert.throws(() => prorate(3100, JAN, FEB, 'nope'), TypeError);
});
