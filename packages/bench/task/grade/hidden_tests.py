"""Hidden acceptance tests. Never copied into a candidate working tree.

Run with the candidate repository as both the working directory and the head of
``sys.path``; ``grade.py`` arranges that. Every test name is prefixed with the
requirement it grades so the grader can bucket results without a lookup table.
"""

from __future__ import annotations

import contextlib
import io
import re
import tempfile
import unittest
from pathlib import Path

from ledger.money import Money, MoneyError
from ledger.parser import LedgerError, load

AMOUNT = re.compile(r"-?\$\d+\.\d{2}")
INTEGER = re.compile(r"\d+")

SAMPLE = "data/sample.csv"
SAMPLE_TOTAL_CENTS = 96895


def cents(text: str) -> int:
    """Turn a rendered ``-$12.34`` back into signed cents."""
    negative = text.lstrip().startswith("-")
    digits = text.replace("-", "").replace("$", "").split(".")
    value = int(digits[0]) * 100 + int(digits[1])
    return -value if negative else value


def run_cli(*argv: str) -> tuple[int, str]:
    """Invoke the ledger CLI in-process, capturing stdout."""
    from ledger.cli import main

    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(argv))
    return code, out.getvalue()


def rejects(*argv: str) -> bool:
    """True when the CLI refuses these arguments instead of succeeding."""
    try:
        code, _ = run_cli(*argv)
    except SystemExit as exc:
        return exc.code not in (0, None)
    except Exception:
        return True
    return code != 0


@contextlib.contextmanager
def ledger_file(text: str):
    """Write ``text`` to a temporary ledger file and yield its path."""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "ledger.csv"
        path.write_text(text, encoding="utf-8")
        yield str(path)


# --------------------------------------------------------------------------- R1


class R1SplitConservesMoney(unittest.TestCase):
    def test_positive_distribution_is_exact(self):
        self.assertEqual(Money(1000).split(3), [Money(334), Money(333), Money(333)])

    def test_negative_distribution_is_exact(self):
        self.assertEqual(Money(-1000).split(3), [Money(-334), Money(-333), Money(-333)])

    def test_prime_split_conserves_and_stays_within_one_cent(self):
        shares = [share.cents for share in Money(100).split(7)]
        self.assertEqual(sum(shares), 100)
        self.assertLessEqual(max(shares) - min(shares), 1)

    def test_descending_magnitude_ordering(self):
        shares = [abs(share.cents) for share in Money(1000).split(7)]
        self.assertEqual(shares, sorted(shares, reverse=True))

    def test_even_split_unchanged(self):
        self.assertEqual(Money(900).split(3), [Money(300)] * 3)

    def test_zero_amount(self):
        self.assertEqual(Money(0).split(4), [Money(0)] * 4)

    def test_zero_ways_raises_money_error(self):
        with self.assertRaises(MoneyError):
            Money(1000).split(0)

    def test_negative_ways_raises_money_error(self):
        with self.assertRaises(MoneyError):
            Money(1000).split(-2)

    def test_large_amount_conserves(self):
        shares = Money(123456789).split(13)
        self.assertEqual(sum(share.cents for share in shares), 123456789)


# --------------------------------------------------------------------------- R2

QUOTED = """\
date,category,description,amount
2026-01-04,groceries,"Coffee, large",4.50
2026-01-05,dining,"He said ""hi"" loudly",12.00
2026-01-06,fuel,plain,20.00
"""

BAD_ROW_AT_LINE_9 = """\
date,category,description,amount
# comment

2026-01-04,groceries,ok,10.00
2026-01-05,groceries,ok,10.00

# another comment
2026-01-06,groceries,ok,10.00
2026-01-04,groceries,mystery,not-an-amount
2026-01-08,groceries,ok,10.00
"""


class R2ParserIsLossless(unittest.TestCase):
    def test_quoted_comma_in_description(self):
        with ledger_file(QUOTED) as path:
            entries = load(path)
        self.assertEqual(entries[0].description, "Coffee, large")

    def test_doubled_quote_escape(self):
        with ledger_file(QUOTED) as path:
            entries = load(path)
        self.assertEqual(entries[1].description, 'He said "hi" loudly')

    def test_quoted_rows_keep_their_amounts(self):
        with ledger_file(QUOTED) as path:
            entries = load(path)
        self.assertEqual([entry.amount for entry in entries][:2], [Money(450), Money(1200)])

    def test_no_rows_are_dropped(self):
        with ledger_file(QUOTED) as path:
            self.assertEqual(len(load(path)), 3)

    def test_unparseable_row_raises_ledger_error(self):
        with ledger_file(BAD_ROW_AT_LINE_9) as path:
            with self.assertRaises(LedgerError):
                load(path)

    def test_error_reports_the_file_line_number(self):
        with ledger_file(BAD_ROW_AT_LINE_9) as path:
            with self.assertRaises(LedgerError) as caught:
                load(path)
            # The temporary path itself carries digits; ignore them.
            message = str(caught.exception).replace(path, "")
        found = {int(match) for match in INTEGER.findall(message)}
        self.assertIn(9, found)

    def test_wrong_field_count_still_rejected(self):
        with ledger_file("2026-01-04,groceries,only-three-fields\n") as path:
            with self.assertRaises(LedgerError):
                load(path)

    def test_comments_blanks_and_header_still_skipped(self):
        text = "date,category,description,amount\n\n# note\n2026-01-04,x,y,1.00\n"
        with ledger_file(text) as path:
            self.assertEqual(len(load(path)), 1)

    def test_sample_ledger_still_loads_unchanged(self):
        entries = load(SAMPLE)
        self.assertEqual(len(entries), 12)
        self.assertEqual(sum(entry.amount.cents for entry in entries), SAMPLE_TOTAL_CENTS)


# --------------------------------------------------------------------------- R3


def split_sections(output: str) -> list[list[str]]:
    """Break ``split`` output into one list of lines per ``Person K`` header."""
    sections: list[list[str]] = []
    for line in output.splitlines():
        if re.match(r"\s*Person\s+\d+\s*$", line):
            sections.append([])
        elif sections:
            sections[-1].append(line)
    return sections


def section_total(lines: list[str]) -> int:
    for line in lines:
        if line.strip().split(":")[0].split()[0:1] == ["TOTAL"]:
            return cents(AMOUNT.search(line).group())
    raise AssertionError("section has no TOTAL line")


class R3SplitSubcommand(unittest.TestCase):
    def test_runs_successfully(self):
        code, _ = run_cli("split", SAMPLE, "--ways", "3")
        self.assertEqual(code, 0)

    def test_one_section_per_person(self):
        _, out = run_cli("split", SAMPLE, "--ways", "3")
        self.assertEqual(len(split_sections(out)), 3)

    def test_ways_defaults_to_two(self):
        _, out = run_cli("split", SAMPLE)
        self.assertEqual(len(split_sections(out)), 2)

    def test_people_totals_sum_to_the_grand_total(self):
        _, out = run_cli("split", SAMPLE, "--ways", "3")
        totals = [section_total(section) for section in split_sections(out)]
        self.assertEqual(sum(totals), SAMPLE_TOTAL_CENTS)

    def test_seven_ways_also_conserves(self):
        _, out = run_cli("split", SAMPLE, "--ways", "7")
        totals = [section_total(section) for section in split_sections(out)]
        self.assertEqual(len(totals), 7)
        self.assertEqual(sum(totals), SAMPLE_TOTAL_CENTS)

    def test_first_section_matches_the_specified_layout(self):
        _, out = run_cli("split", SAMPLE, "--ways", "2")
        first = [line.strip() for line in split_sections(out)[0] if line.strip()]
        self.assertEqual(
            [re.sub(r"\s+", " ", line) for line in first],
            [
                "dining $86.46",
                "fuel $71.62",
                "groceries $237.72",
                "tools $88.70",
                "TOTAL $484.50",
            ],
        )

    def test_each_person_sees_every_category(self):
        _, out = run_cli("split", SAMPLE, "--ways", "4")
        for section in split_sections(out):
            body = "\n".join(section)
            for category in ("dining", "fuel", "groceries", "tools"):
                self.assertIn(category, body)

    def test_zero_ways_rejected(self):
        self.assertEqual(run_cli("split", SAMPLE, "--ways", "2")[0], 0)
        self.assertTrue(rejects("split", SAMPLE, "--ways", "0"))

    def test_negative_ways_rejected(self):
        self.assertEqual(run_cli("split", SAMPLE, "--ways", "2")[0], 0)
        self.assertTrue(rejects("split", SAMPLE, "--ways", "-3"))


# --------------------------------------------------------------------------- R4


def summary_rows(output: str) -> list[tuple[str, int]]:
    """Parse ``summary`` output into ``(bucket, cents)`` pairs, TOTAL excluded."""
    rows = []
    for line in output.splitlines():
        match = AMOUNT.search(line)
        if match is None:
            continue
        name = line[: match.start()].strip()
        if name.upper() == "TOTAL":
            continue
        rows.append((name, cents(match.group())))
    return rows


def summary_total(output: str) -> int:
    for line in output.splitlines():
        if line.strip().upper().startswith("TOTAL"):
            return cents(AMOUNT.search(line).group())
    raise AssertionError("no TOTAL line")


class R4TopBuckets(unittest.TestCase):
    def test_top_limits_the_bucket_count(self):
        _, out = run_cli("summary", SAMPLE, "--top", "2")
        self.assertEqual(len(summary_rows(out)), 3)

    def test_buckets_are_the_two_largest_ranked_first(self):
        _, out = run_cli("summary", SAMPLE, "--top", "2")
        self.assertEqual([name for name, _ in summary_rows(out)][:2], ["groceries", "tools"])

    def test_other_holds_the_folded_remainder(self):
        _, out = run_cli("summary", SAMPLE, "--top", "2")
        folded = dict(summary_rows(out))["Other"]
        self.assertEqual(folded, 17290 + 14324)

    def test_other_is_printed_last(self):
        _, out = run_cli("summary", SAMPLE, "--top", "1")
        self.assertEqual(summary_rows(out)[-1][0], "Other")

    def test_total_is_still_the_true_total(self):
        _, out = run_cli("summary", SAMPLE, "--top", "1")
        self.assertEqual(summary_total(out), SAMPLE_TOTAL_CENTS)

    def test_other_omitted_when_nothing_is_folded(self):
        _, out = run_cli("summary", SAMPLE, "--top", "4")
        self.assertNotIn("Other", [name for name, _ in summary_rows(out)])

    def test_top_larger_than_bucket_count_omits_other(self):
        _, out = run_cli("summary", SAMPLE, "--top", "99")
        self.assertNotIn("Other", [name for name, _ in summary_rows(out)])

    def test_top_works_with_month_grouping(self):
        _, out = run_cli("summary", SAMPLE, "--by", "month", "--top", "1")
        rows = summary_rows(out)
        self.assertEqual([name for name, _ in rows], ["2026-02", "Other"])

    def test_zero_top_rejected(self):
        self.assertEqual(run_cli("summary", SAMPLE, "--top", "2")[0], 0)
        self.assertTrue(rejects("summary", SAMPLE, "--top", "0"))

    def test_summary_without_top_is_unchanged(self):
        _, out = run_cli("summary", SAMPLE)
        self.assertEqual(
            summary_rows(out),
            [("dining", 17290), ("fuel", 14324), ("groceries", 47542), ("tools", 17739)],
        )
        self.assertEqual(summary_total(out), SAMPLE_TOTAL_CENTS)


if __name__ == "__main__":
    unittest.main()
