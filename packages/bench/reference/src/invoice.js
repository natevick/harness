import { sumCents } from './money.js';
import { lineTotal } from './lineitem.js';
import { applyDiscounts } from './discount.js';
import { computeTax } from './tax.js';
import { isCouponValid } from './coupon.js';

/**
 * Assemble a finished invoice.
 *
 * Order of operations:
 *   1. `subtotalCents` is the sum of every line total
 *   2. coupons that are not redeemable at `asOf` are dropped; the discounts
 *      carried by the surviving coupons are appended to the explicit discounts
 *   3. the discounts are applied to the subtotal
 *   4. tax is charged on the *discounted* amount, never on the subtotal
 *   5. `totalCents` is the discounted amount plus tax
 *
 * @param {{
 *   lines: Array<object>,
 *   discounts?: Array<object>,
 *   coupons?: Array<object>,
 *   taxRules?: Array<object>,
 *   asOf: string
 * }} input
 * @returns {{
 *   subtotalCents: number,
 *   discountCents: number,
 *   taxLines: Array<{name: string, cents: number}>,
 *   taxCents: number,
 *   totalCents: number
 * }}
 */
export function buildInvoice({ lines, discounts = [], coupons = [], taxRules = [], asOf }) {
  if (!Array.isArray(lines) || lines.length === 0) {
    throw new RangeError('an invoice needs at least one line');
  }
  const subtotalCents = sumCents(lines.map(lineTotal));
  const liveCoupons = coupons.filter((c) => isCouponValid(c, asOf));
  const allDiscounts = [...discounts, ...liveCoupons.map((c) => c.discount)];
  const discountedCents = applyDiscounts(subtotalCents, allDiscounts);
  const tax = computeTax(discountedCents, taxRules);
  return {
    subtotalCents,
    discountCents: subtotalCents - discountedCents,
    taxLines: tax.lines,
    taxCents: tax.totalCents,
    totalCents: discountedCents + tax.totalCents,
  };
}
