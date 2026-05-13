"""
Shared DNS entry validator for the AEGIS-DNS pipeline.

Single source of truth used by stages 1 (cleanup), 1.5 (reconciliation),
and any other component that needs to decide whether a string is an
acceptable allow/block entry.

API:
    validate_entry(s, valid_tlds) -> ValidationResult
    load_iana_tlds(path) -> set[str]
"""
from __future__ import annotations

import ipaddress
import re
import urllib.request
from pathlib import Path
from typing import NamedTuple

IANA_TLDS_URL = "https://data.iana.org/TLD/tlds-alpha-by-domain.txt"

# RFC-1035-style single label: alnum + hyphen, no leading/trailing hyphen,
# 1-63 chars. Underscores are rejected — DNS records may permit them but
# blocklist consumers generally do not.
_LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


class ValidationResult(NamedTuple):
    valid: bool
    normalized: str  # lowercased, trailing-dot-stripped; empty if invalid
    kind: str        # "domain", "ipv4", or "" if invalid
    reason: str      # short tag if invalid; empty if valid


def load_iana_tlds(path: Path) -> set[str]:
    """Parse IANA tlds-alpha-by-domain.txt into an uppercased set of labels."""
    tlds: set[str] = set()
    with path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            tlds.add(line.upper())
    return tlds


def load_or_fetch_iana_tlds(cache_path: Path) -> set[str]:
    """
    Load IANA TLDs from cache_path. If the cache is missing, fetch the live
    list from IANA and write to cache_path. Raises FileNotFoundError if both
    paths fail.
    """
    if not cache_path.exists():
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with urllib.request.urlopen(IANA_TLDS_URL, timeout=30) as resp:
                content = resp.read()
            cache_path.write_bytes(content)
        except Exception as exc:
            raise FileNotFoundError(
                f"IANA TLD cache missing at {cache_path} and fetch failed: {exc}"
            )
    return load_iana_tlds(cache_path)


def _is_ipv4(s: str) -> bool:
    try:
        ipaddress.IPv4Address(s)
        return True
    except ValueError:
        return False


def validate_entry(s: str | None, valid_tlds: set[str]) -> ValidationResult:
    """
    Validate and normalize a DNS allow/block entry.

    Accepts:
        - FQDN: app.example.com
        - Wildcard FQDN with one or more leading "*." prefixes: *.example.com,
          *.*.example.com (rare, but legal for some consumers)
        - IPv4 address: 1.2.3.4

    Rejects:
        - Blank / whitespace-only / internal-whitespace input
        - Oversized labels (>63) or total (>253)
        - Mid-string or malformed wildcards (foo*.bar, *foo.bar, *.foo.*.bar)
        - Single-label entries (com, localhost)
        - Numeric TLDs and TLDs not in the supplied IANA set
        - IPv4 with a wildcard prefix (meaningless)
    """
    if s is None:
        return ValidationResult(False, "", "", "blank_or_whitespace")

    stripped = s.strip()
    if not stripped:
        return ValidationResult(False, "", "", "blank_or_whitespace")

    if any(c.isspace() for c in stripped):
        return ValidationResult(False, "", "", "internal_whitespace")

    lowered = stripped.lower().rstrip(".")
    if not lowered:
        return ValidationResult(False, "", "", "blank_or_whitespace")

    base = lowered
    while base.startswith("*."):
        base = base[2:]

    if not base or base == "*":
        return ValidationResult(False, "", "", "wildcard_as_tld")

    had_wildcard = base != lowered

    if "*" in base:
        return ValidationResult(False, "", "", "malformed_wildcard")

    if _is_ipv4(base):
        if had_wildcard:
            return ValidationResult(False, "", "", "wildcard_with_ipv4")
        return ValidationResult(True, base, "ipv4", "")

    if len(base) > 253:
        return ValidationResult(False, "", "", "oversized_total")

    labels = base.split(".")
    if len(labels) < 2:
        return ValidationResult(False, "", "", "single_label")

    for label in labels:
        if not label:
            return ValidationResult(False, "", "", "empty_label")
        if len(label) > 63:
            return ValidationResult(False, "", "", "oversized_label")
        if not _LABEL_RE.match(label):
            return ValidationResult(False, "", "", "invalid_label_chars")

    tld = labels[-1]
    if tld.isdigit():
        return ValidationResult(False, "", "", "numeric_tld")
    if tld.upper() not in valid_tlds:
        return ValidationResult(False, "", "", "invalid_tld")

    return ValidationResult(True, lowered, "domain", "")
