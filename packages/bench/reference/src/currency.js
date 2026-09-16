// Human-readable rendering of integer-cent amounts.

const SYMBOLS = {
  USD: '$',
  EUR: '€',
  GBP: '£',
  JPY: '¥',
};

/**
 * Render integer cents as a currency string.
 *
 * The fractional part is always exactly two digits, so 5 renders as "$0.05"
 * and 1000 renders as "$10.00". Negative amounts are prefixed with a single
 * minus sign ahead of the symbol, e.g. "-$1.00". No thousands separators are
 * emitted: 1234567 renders as "$12345.67".
 *
 * @param {number} cents integer cents
 * @param {string} [currency] ISO 4217 code
 * @returns {string}
 */
export function formatCents(cents, currency = 'USD') {
  const symbol = SYMBOLS[currency] ?? '$';
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  const whole = Math.floor(abs / 100);
  const fraction = String(abs % 100).padStart(2, '0');
  return `${sign}${symbol}${whole}.${fraction}`;
}
