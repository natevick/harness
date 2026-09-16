import { mulCents } from './money.js';

/**
 * Compute tax lines for a taxable amount.
 *
 * A rule with `compound: false` is charged on the taxable amount alone.
 * A rule with `compound: true` is charged on the taxable amount *plus* all tax
 * accumulated by the rules ahead of it, in the order the rules are given —
 * this is how e.g. Quebec's QST stacks on top of the federal GST.
 *
 * @param {number} taxableCents integer cents
 * @param {Array<{name: string, rate: number, compound?: boolean}>} [rules]
 * @returns {{lines: Array<{name: string, cents: number}>, totalCents: number}}
 */
export function computeTax(taxableCents, rules = []) {
  const lines = [];
  let accumulated = 0;
  for (const rule of rules) {
    const base = rule.compound ? taxableCents + accumulated : taxableCents;
    const cents = mulCents(base, rule.rate);
    lines.push({ name: rule.name, cents });
    accumulated += cents;
  }
  return { lines, totalCents: accumulated };
}
