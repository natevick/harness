#!/usr/bin/env python3
"""Apply the known-good solution to reference/src, proving the fixture is solvable."""
import pathlib
import sys

ROOT = pathlib.Path(__file__).parent / "reference" / "src"

TO_CENTS_NEW = """  // Scale on the decimal text, not the float: 1.005 * 100 is 100.49999999999999.
  const text = typeof amount === 'string' ? amount.trim() : n.toFixed(12);
  const parts = /^([+-]?)(\\d*)(?:\\.(\\d*))?$/.exec(text);
  if (!parts) {
    throw new TypeError(`not a decimal amount: ${amount}`);
  }
  const sign = parts[1] === '-' ? -1 : 1;
  const whole = Number(parts[2] || '0');
  const fraction = (parts[3] ?? '').padEnd(3, '0');
  let cents = whole * 100 + Number(fraction.slice(0, 2));
  if (Number(fraction[2]) >= 5) {
    cents += 1;
  }
  return sign * cents;
}"""

DISCOUNT_NEW = """  for (const d of discounts) {
    if (d.type !== 'percent' && d.type !== 'fixed') {
      throw new Error(`unknown discount type: ${d.type}`);
    }
  }
  let total = subtotalCents;
  for (const d of discounts.filter((x) => x.type === 'percent')) {
    total -= mulCents(subtotalCents, d.rate);
  }
  for (const d of discounts.filter((x) => x.type === 'fixed')) {
    total -= d.amountCents;
  }
  return Math.max(0, total);
}"""

DISCOUNT_OLD = """  let total = subtotalCents;
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
}"""

PATCHES = [
    # 1. toCents: float scaling loses the tie at the third decimal
    ("money.js", "  return Math.round(n * 100);\n}", TO_CENTS_NEW),
    # 2. mulCents: Math.round breaks ties toward +Infinity, not away from zero
    (
        "money.js",
        "  assertCents(cents);\n  return Math.round(cents * rate);",
        "  assertCents(cents);\n  const exact = cents * rate;\n"
        "  return Math.sign(exact) * Math.round(Math.abs(exact));",
    ),
    # 3. formatCents: fractional part not zero-padded
    (
        "currency.js",
        "  const fraction = abs % 100;",
        "  const fraction = String(abs % 100).padStart(2, '0');",
    ),
    # 4. lineTotal: discount rounded per unit instead of per line
    (
        "lineitem.js",
        "  const unitNet = item.unitPriceCents - mulCents(item.unitPriceCents, rate);\n"
        "  return unitNet * item.quantity;",
        "  const gross = item.unitPriceCents * item.quantity;\n"
        "  return gross - mulCents(gross, rate);",
    ),
    # 5. applyDiscounts: input order honoured, percents compound, no zero floor
    ("discount.js", DISCOUNT_OLD, DISCOUNT_NEW),
    # 6. computeTax: compound flag ignored
    (
        "tax.js",
        "    const base = taxableCents;",
        "    const base = rule.compound ? taxableCents + accumulated : taxableCents;",
    ),
    # 7a. isCouponValid: expiry treated as exclusive
    (
        "coupon.js",
        "  if (at >= Date.parse(coupon.expiresAt)) {",
        "  if (at > Date.parse(coupon.expiresAt)) {",
    ),
    # 7b. isCouponValid: usage cap off by one
    (
        "coupon.js",
        "  if (coupon.usageCount > coupon.maxUses) {",
        "  if (coupon.usageCount >= coupon.maxUses) {",
    ),
    # 8. prorate: half-open period counted inclusively
    (
        "proration.js",
        "  const periodDays = (end - start) / DAY_MS + 1;",
        "  const periodDays = (end - start) / DAY_MS;",
    ),
    # 9. buildInvoice: tax charged on the pre-discount subtotal
    (
        "invoice.js",
        "  const tax = computeTax(subtotalCents, taxRules);",
        "  const tax = computeTax(discountedCents, taxRules);",
    ),
]

failed = False
for filename, old, new in PATCHES:
    path = ROOT / filename
    text = path.read_text()
    if text.count(old) != 1:
        print(f"FAIL {filename}: expected 1 match, found {text.count(old)}")
        failed = True
        continue
    path.write_text(text.replace(old, new))
    print(f"ok   {filename}: {old.strip().splitlines()[0][:60]}")

sys.exit(1 if failed else 0)
