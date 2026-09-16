import { assertCents, mulCents } from './money.js';

/**
 * Net total for a single invoice line.
 *
 * The line-level percent discount applies to the *line total*, not to the unit
 * price, so rounding happens exactly once per line rather than once per unit.
 *
 * @param {{unitPriceCents: number, quantity: number, discountRate?: number}} item
 * @returns {number} integer cents
 */
export function lineTotal(item) {
  assertCents(item.unitPriceCents);
  if (!Number.isInteger(item.quantity) || item.quantity < 1) {
    throw new RangeError(`quantity must be a positive integer, got ${item.quantity}`);
  }
  const rate = item.discountRate ?? 0;
  if (rate < 0 || rate > 1) {
    throw new RangeError(`discountRate must be within [0, 1], got ${rate}`);
  }
  const gross = item.unitPriceCents * item.quantity;
  return gross - mulCents(gross, rate);
}
