import { mulCents } from './money.js';

/**
 * Apply a set of discounts to a subtotal.
 *
 * The order of operations is fixed by the pricing rules and does *not* depend
 * on the order the discounts are supplied in:
 *
 *   1. every percent discount, each one computed against the original
 *      subtotal (percent discounts never compound with each other)
 *   2. then every fixed discount
 *
 * The result is floored at zero — a discount can never produce a credit.
 *
 * @param {number} subtotalCents integer cents
 * @param {Array<{type: 'percent', rate: number}|{type: 'fixed', amountCents: number}>} [discounts]
 * @returns {number} integer cents
 */
export function applyDiscounts(subtotalCents, discounts = []) {
  let total = subtotalCents;
  for (const d of discounts) {
    if (d.type === 'percent') {
      total -= mulCents(total, d.rate);
    } else if (d.type === 'fixed') {
      total -= d.amountCents;
    } else {
      throw new Error(`unknown discount type: ${d.type}`);
    }
  }
  return total;
}
