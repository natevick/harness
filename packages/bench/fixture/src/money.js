// Integer-cents money primitives.
//
// Every monetary amount in this codebase is an integer number of cents.
// Floats are never stored, only used transiently inside these helpers.

/**
 * Assert that a value is a legal integer-cent amount and return it.
 *
 * @throws {TypeError} if the value is not an integer.
 */
export function assertCents(value) {
  if (!Number.isInteger(value)) {
    throw new TypeError(`amount must be integer cents, got ${value}`);
  }
  return value;
}

/**
 * Parse a decimal amount into integer cents.
 *
 * Accepts a number or a decimal string with up to three fractional digits.
 * The third fractional digit is resolved by rounding half away from zero,
 * so "1.005" is 101 cents and "-1.005" is -101 cents.
 *
 * @param {number|string} amount
 * @returns {number} integer cents
 */
export function toCents(amount) {
  const n = typeof amount === 'string' ? parseFloat(amount) : amount;
  if (!Number.isFinite(n)) {
    throw new TypeError(`not a finite amount: ${amount}`);
  }
  return Math.round(n * 100);
}

/**
 * Multiply an integer-cent amount by a rate and return integer cents.
 *
 * Ties round half away from zero: 50.5 becomes 51, -50.5 becomes -51.
 *
 * @param {number} cents integer cents
 * @param {number} rate  multiplier
 * @returns {number} integer cents
 */
export function mulCents(cents, rate) {
  assertCents(cents);
  return Math.round(cents * rate);
}

/**
 * Sum a list of integer-cent amounts.
 *
 * @param {number[]} list
 * @returns {number} integer cents
 */
export function sumCents(list) {
  return list.reduce((acc, v) => acc + assertCents(v), 0);
}
