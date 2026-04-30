#!/usr/bin/env python3
"""
Normalize a DNS allow/block list file using the shared validator.

Reads input line-by-line; valid domain entries are written to output (one per
line, normalized). Invalid lines are dropped and (optionally) appended to a
detail log in the same TSV format used by 1.5-reconciliation.sh:

    run_ts \t side \t src \t action \t reason \t original \t normalized

IPv4 entries are dropped here on purpose: 1.5-reconciliation.sh operates on
domain files only (per repo layout: public_*_lists/domains/).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from validate import load_iana_tlds, validate_entry  # noqa: E402 — co-located


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--tlds", type=Path, required=True)
    parser.add_argument("--detail-log", type=Path, default=None)
    parser.add_argument("--side", default="", choices=["allow", "block", ""])
    parser.add_argument("--run-ts", default="")
    args = parser.parse_args()

    tlds = load_iana_tlds(args.tlds)

    input_lines = 0
    kept = 0
    removed = 0

    detail_fh = (
        args.detail_log.open("a", encoding="utf-8") if args.detail_log else None
    )
    try:
        with args.input.open("r", encoding="utf-8", errors="ignore") as fin, \
                args.output.open("w", encoding="utf-8") as fout:
            for raw in fin:
                input_lines += 1
                original = raw.rstrip("\n").rstrip("\r")
                result = validate_entry(raw, tlds)
                if result.valid and result.kind == "domain":
                    fout.write(result.normalized + "\n")
                    kept += 1
                    continue

                removed += 1
                if detail_fh is not None:
                    reason = result.reason or "non_domain_kind"
                    detail_fh.write(
                        f"{args.run_ts}\t{args.side}\t{args.input}\tremove\t"
                        f"{reason}\t{original}\t\n"
                    )
    finally:
        if detail_fh is not None:
            detail_fh.close()

    # Caller-parseable summary on stderr.
    print(
        f"normalize\t{args.input}\t{input_lines}\t{kept}\t{removed}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
