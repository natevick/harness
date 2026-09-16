/**
 * Decide whether a coupon may be redeemed at a given instant.
 *
 * A coupon is valid when all three hold:
 *   - the instant is at or after `validFrom`   (the first moment counts)
 *   - the instant is at or before `expiresAt`  (the last moment counts)
 *   - `usageCount` is strictly below `maxUses`
 *
 * All timestamps are ISO-8601 UTC strings.
 *
 * @param {{validFrom: string, expiresAt: string, usageCount: number, maxUses: number}} coupon
 * @param {string} atISO
 * @returns {boolean}
 */
export function isCouponValid(coupon, atISO) {
  const at = Date.parse(atISO);
  if (Number.isNaN(at)) {
    throw new TypeError(`bad timestamp: ${atISO}`);
  }
  if (at < Date.parse(coupon.validFrom)) {
    return false;
  }
  if (at >= Date.parse(coupon.expiresAt)) {
    return false;
  }
  if (coupon.usageCount > coupon.maxUses) {
    return false;
  }
  return true;
}
