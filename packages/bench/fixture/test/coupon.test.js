import test from 'node:test';
import assert from 'node:assert/strict';
import { isCouponValid } from '../src/coupon.js';

const base = {
  validFrom: '2026-03-01T00:00:00Z',
  expiresAt: '2026-03-31T23:59:59Z',
  usageCount: 0,
  maxUses: 5,
};

test('a coupon is valid on the first and the last instant of its window', () => {
  assert.equal(isCouponValid(base, '2026-03-01T00:00:00Z'), true);
  assert.equal(isCouponValid(base, '2026-03-31T23:59:59Z'), true);
});

test('a coupon is invalid outside its window', () => {
  assert.equal(isCouponValid(base, '2026-02-28T23:59:59Z'), false);
  assert.equal(isCouponValid(base, '2026-04-01T00:00:00Z'), false);
});

test('usage is exhausted once the count reaches the cap', () => {
  assert.equal(isCouponValid({ ...base, usageCount: 4 }, '2026-03-15T00:00:00Z'), true);
  assert.equal(isCouponValid({ ...base, usageCount: 5 }, '2026-03-15T00:00:00Z'), false);
  assert.equal(isCouponValid({ ...base, usageCount: 6 }, '2026-03-15T00:00:00Z'), false);
});

test('an unparseable instant is an error', () => {
  assert.throws(() => isCouponValid(base, 'yesterday'), TypeError);
});
