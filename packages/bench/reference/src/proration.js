import { mulCents } from './money.js';

const DAY_MS = 86400000;

/**
 * Prorate an amount across the unused remainder of a billing period.
 *
 * A billing period is half-open: `[periodStart, periodEnd)`. `periodDays` is
 * therefore the count of whole days in that half-open interval — a period from
 * 2026-01-01 to 2026-02-01 is 31 days, not 32. `remainingDays` is the count of
 * whole days in `[changeAt, periodEnd)`.
 *
 * The prorated amount is `amountCents × remainingDays / periodDays`, rounded
 * by {@link mulCents}. A change at the very start of the period therefore
 * prorates to the full amount, and a change at the period end prorates to zero.
 *
 * @param {number} amountCents integer cents
 * @param {string} periodStartISO
 * @param {string} periodEndISO
 * @param {string} changeAtISO
 * @returns {number} integer cents
 */
export function prorate(amountCents, periodStartISO, periodEndISO, changeAtISO) {
  const start = Date.parse(periodStartISO);
  const end = Date.parse(periodEndISO);
  const change = Date.parse(changeAtISO);
  if ([start, end, change].some(Number.isNaN)) {
    throw new TypeError('all three timestamps must be parseable');
  }
  if (end <= start) {
    throw new RangeError('period end must be after period start');
  }
  if (change < start || change > end) {
    throw new RangeError('change instant falls outside the billing period');
  }
  const periodDays = (end - start) / DAY_MS;
  const remainingDays = (end - change) / DAY_MS;
  return mulCents(amountCents, remainingDays / periodDays);
}
