"""Tests for pipeline/lib/validate.py — the shared DNS entry validator.

Uses stdlib unittest only, so no pip install is required to run:

    python3 -m unittest pipeline.lib.test_validate
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Make pipeline/lib/python importable when running from anywhere.
_HERE = Path(__file__).resolve().parent
_LIB = _HERE.parent.parent / "lib" / "python"
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))

from validate import (  # noqa: E402
    ValidationResult,
    load_iana_tlds,
    validate_entry,
)


# A small fixture TLD set covering everything the tests reference.
TLDS = {"COM", "NET", "ORG", "IO", "CO", "UK"}


VALID_CASES = [
    # (raw, expected_norm, expected_kind)
    ("example.com", "example.com", "domain"),
    ("EXAMPLE.COM", "example.com", "domain"),
    ("example.com.", "example.com", "domain"),
    ("  example.com  ", "example.com", "domain"),
    ("a.b.c.example.com", "a.b.c.example.com", "domain"),
    ("xn--bcher-kva.com", "xn--bcher-kva.com", "domain"),
    ("a-b.example.com", "a-b.example.com", "domain"),
    ("1.2.3.4", "1.2.3.4", "ipv4"),
    ("0.0.0.0", "0.0.0.0", "ipv4"),
    ("255.255.255.255", "255.255.255.255", "ipv4"),
    ("*.example.com", "*.example.com", "domain"),
    ("*.*.example.com", "*.*.example.com", "domain"),
    ("co.uk", "co.uk", "domain"),
    ("a.io", "a.io", "domain"),
    ("a" * 63 + ".example.com", "a" * 63 + ".example.com", "domain"),
]


INVALID_CASES = [
    # (raw, expected_reason)
    (None, "blank_or_whitespace"),
    ("", "blank_or_whitespace"),
    ("   ", "blank_or_whitespace"),
    (".", "blank_or_whitespace"),
    ("...", "blank_or_whitespace"),

    ("foo bar.com", "internal_whitespace"),
    ("foo\tbar.com", "internal_whitespace"),
    ("foo\nbar.com", "internal_whitespace"),

    ("a" * 64 + ".example.com", "oversized_label"),
    (".".join(["a" * 63, "b" * 63, "c" * 63, "d" * 63]) + ".com", "oversized_total"),

    ("foo..example.com", "empty_label"),

    ("localhost", "single_label"),
    ("com", "single_label"),

    ("-foo.example.com", "invalid_label_chars"),
    ("foo-.example.com", "invalid_label_chars"),
    ("foo_bar.example.com", "invalid_label_chars"),
    ("foo!.example.com", "invalid_label_chars"),

    ("foo*.example.com", "malformed_wildcard"),
    ("*foo.example.com", "malformed_wildcard"),
    ("foo.*.example.com", "malformed_wildcard"),
    ("*.", "wildcard_as_tld"),

    ("*.1.2.3.4", "wildcard_with_ipv4"),

    ("example.notarealtld", "invalid_tld"),
    ("foo.123", "numeric_tld"),
]


class ValidateEntryTests(unittest.TestCase):
    def test_valid_cases(self):
        for raw, expected_norm, expected_kind in VALID_CASES:
            with self.subTest(raw=raw):
                result = validate_entry(raw, TLDS)
                self.assertTrue(result.valid, f"{raw!r}: {result.reason}")
                self.assertEqual(result.normalized, expected_norm)
                self.assertEqual(result.kind, expected_kind)
                self.assertEqual(result.reason, "")

    def test_invalid_cases(self):
        for raw, expected_reason in INVALID_CASES:
            with self.subTest(raw=raw):
                result = validate_entry(raw, TLDS)
                self.assertFalse(result.valid, f"expected rejection of {raw!r}")
                self.assertEqual(
                    result.reason,
                    expected_reason,
                    f"{raw!r}: expected {expected_reason!r}, got {result.reason!r}",
                )
                self.assertEqual(result.normalized, "")
                self.assertEqual(result.kind, "")

    def test_returns_named_tuple(self):
        r = validate_entry("example.com", TLDS)
        self.assertIsInstance(r, ValidationResult)
        valid, normalized, kind, reason = r
        self.assertEqual((valid, normalized, kind, reason), (True, "example.com", "domain", ""))

    def test_empty_tld_set_rejects_everything_domain(self):
        r = validate_entry("example.com", set())
        self.assertFalse(r.valid)
        self.assertEqual(r.reason, "invalid_tld")

    def test_empty_tld_set_still_accepts_ipv4(self):
        r = validate_entry("1.2.3.4", set())
        self.assertTrue(r.valid)
        self.assertEqual(r.kind, "ipv4")


class LoadIanaTldsTests(unittest.TestCase):
    def test_skips_comments_and_blanks(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "tlds.txt"
            p.write_text(
                "# Version 1, Last Updated ...\n\nCOM\nNET\n# trailing comment\n",
                encoding="utf-8",
            )
            self.assertEqual(load_iana_tlds(p), {"COM", "NET"})

    def test_uppercases(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "tlds.txt"
            p.write_text("com\nNet\nOrG\n", encoding="utf-8")
            self.assertEqual(load_iana_tlds(p), {"COM", "NET", "ORG"})


if __name__ == "__main__":
    unittest.main()
