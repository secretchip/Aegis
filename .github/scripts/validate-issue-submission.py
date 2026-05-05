#!/usr/bin/env python3
"""
Parse a submission issue body, validate the proposed entries via the shared
DNS validator, and emit:
  - $GITHUB_OUTPUT  validation_summary, valid_count, invalid_count, side
                    has_valid (true/false), suggested_label
  - <stdout>        Markdown comment body for the issue (multi-line; the
                    workflow uses gh issue comment --body-file -)
  - var/submission/<issue-number>/valid.txt   sorted list of validated
                    entries, ready to append to sources/pins/<side>.txt
                    when the maintainer applies the `approved` label.

Reads the entire issue body from $ISSUE_BODY. The block expected is the
"Domains" section's textarea contents (rendered by the Issue Forms as a
fenced markdown block whose heading text starts with the field's label).

Side detection ("block" vs "allow") uses the issue's labels in
$ISSUE_LABELS (comma-separated). Recognized: type:block, type:allow.
False-positive issues map to allow.

Exit code is 0 unless required env is missing.
"""
from __future__ import annotations

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
# Validator is co-located in this directory (in the public repo it's a
# regular file copied by the sync script; in the local build repo it's a
# symlink pointing at pipeline/lib/python/validate.py — same source of
# truth either way).
sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate import load_or_fetch_iana_tlds, validate_entry  # noqa: E402

TRAILING_COMMENT_RE = re.compile(r"\s*#.*$")

# Strip Issue-Form headers like "### Domains to block" so the value chunks
# are easy to slice. The form puts each field as `### Label\n\n<value>\n`.
SECTION_HEADER_RE = re.compile(r"^###\s+", re.MULTILINE)


def detect_side(labels: str) -> str:
    """Return "block" or "allow" based on the issue labels."""
    parts = {p.strip().lower() for p in labels.split(",")}
    if "type:allow" in parts or "false-positive" in parts:
        return "allow"
    if "type:block" in parts:
        return "block"
    # Fallback for unknown / hand-edited issues — default to allow because
    # an erroneous allow-add is recoverable; an erroneous block-add isn't.
    return "allow"


def extract_domains_section(body: str) -> str:
    """
    Find the section whose heading mentions 'domain' or 'wrongly-blocked'
    or 'list url' (single-URL submission), and return its raw text.
    """
    if not body:
        return ""
    sections = SECTION_HEADER_RE.split(body)
    # sections[0] is text before any '### ' header; subsequent items begin
    # with the heading text. We want the first section whose heading
    # mentions 'domain' or 'wrongly-blocked'.
    for chunk in sections[1:]:
        head, _, value = chunk.partition("\n")
        head_l = head.lower().strip()
        if (
            "domain" in head_l
            or "wrongly-blocked" in head_l
            or "list url" in head_l
        ):
            return value
    # Fallback: return the whole body (the user may have submitted via the
    # plain-edit textarea instead of the form).
    return body


def parse_lines(section: str) -> list[tuple[int, str]]:
    """Strip code fences + trailing comments, return [(line_no, value)]."""
    out: list[tuple[int, str]] = []
    for raw_line_no, raw in enumerate(section.splitlines(), start=1):
        s = raw.strip()
        # Skip Issue Form's fenced code markers and "_No response_" placeholder.
        if not s or s.startswith("```") or s == "_No response_":
            continue
        # Skip full-line comments (Issue Form rendering may include them).
        if s.startswith("#"):
            continue
        # Strip trailing comments.
        s = TRAILING_COMMENT_RE.sub("", s).strip()
        if not s:
            continue
        out.append((raw_line_no, s))
    return out


def main() -> int:
    issue_number = os.environ.get("ISSUE_NUMBER", "0")
    issue_body = os.environ.get("ISSUE_BODY", "")
    issue_labels = os.environ.get("ISSUE_LABELS", "")

    side = detect_side(issue_labels)
    section = extract_domains_section(issue_body)
    items = parse_lines(section)

    if not items:
        print(f"_No domain entries detected in this submission. Did you fill the form?_")
        emit_output("validation_summary", "no_entries")
        emit_output("valid_count", "0")
        emit_output("invalid_count", "0")
        emit_output("side", side)
        emit_output("has_valid", "false")
        emit_output("suggested_label", "needs-info")
        return 0

    tld_cache = REPO_ROOT / "var" / "state" / "iana-tlds.txt"
    tld_cache.parent.mkdir(parents=True, exist_ok=True)
    valid_tlds = load_or_fetch_iana_tlds(tld_cache)

    valid_entries: list[str] = []
    invalid_entries: list[tuple[int, str, str]] = []
    for line_no, value in items:
        result = validate_entry(value, valid_tlds)
        if result.valid:
            valid_entries.append(result.normalized)
        else:
            invalid_entries.append((line_no, value, result.reason))

    # Persist validated entries for the auto-PR workflow to pick up later.
    out_dir = REPO_ROOT / "var" / "submission" / str(issue_number)
    out_dir.mkdir(parents=True, exist_ok=True)
    valid_path = out_dir / "valid.txt"
    valid_path.write_text(
        "\n".join(sorted(set(valid_entries))) + ("\n" if valid_entries else ""),
        encoding="utf-8",
    )

    # Markdown comment body
    lines: list[str] = []
    lines.append(f"### Validation report — issue #{issue_number}")
    lines.append("")
    lines.append(f"Detected side: **{side}**.")
    lines.append("")
    if valid_entries:
        lines.append(f"#### ✓ {len(valid_entries)} valid entry(ies)")
        lines.append("")
        lines.append("```")
        for entry in sorted(set(valid_entries)):
            lines.append(entry)
        lines.append("```")
        lines.append("")
    if invalid_entries:
        lines.append(f"#### ✗ {len(invalid_entries)} invalid entry(ies)")
        lines.append("")
        lines.append("| line | value | reason |")
        lines.append("| ---- | ----- | ------ |")
        for line_no, value, reason in invalid_entries:
            v = value.replace("|", r"\|")
            lines.append(f"| {line_no} | `{v}` | `{reason}` |")
        lines.append("")
        lines.append(
            "Fix the invalid entries by editing the issue, then a new "
            "validation report will replace this one."
        )
        lines.append("")
    lines.append("---")
    lines.append("")
    if valid_entries and not invalid_entries:
        lines.append(
            "✅ All entries are valid. A maintainer will review and apply the "
            "`approved` label if accepted; that triggers an auto-PR adding the "
            "entries to `sources/pins/{}.txt`.".format(side)
        )
    elif valid_entries:
        lines.append(
            "⚠️ Some entries are invalid. The validator will only forward the "
            "valid ones if a maintainer approves; please fix or remove the "
            "invalid entries above."
        )
    else:
        lines.append("❌ No entries were valid. Edit the issue to correct them.")
    lines.append("")
    lines.append(
        f"_Validated at {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}; "
        f"see [docs/manual.md](../blob/main/docs/manual.md#6-validation-rules) "
        f"for validator rules._"
    )

    body_md = "\n".join(lines) + "\n"
    print(body_md)

    summary = (
        "all_valid"
        if valid_entries and not invalid_entries
        else "partial"
        if valid_entries
        else "no_valid"
    )
    suggested_label = {
        "all_valid": "valid-submission",
        "partial": "needs-fix",
        "no_valid": "needs-fix",
        "no_entries": "needs-info",
    }[summary]

    emit_output("validation_summary", summary)
    emit_output("valid_count", str(len(valid_entries)))
    emit_output("invalid_count", str(len(invalid_entries)))
    emit_output("side", side)
    emit_output("has_valid", "true" if valid_entries else "false")
    emit_output("suggested_label", suggested_label)
    emit_output("valid_path", str(valid_path))

    return 0


def emit_output(key: str, value: str) -> None:
    """Append key=value to $GITHUB_OUTPUT (workflow steps consume these)."""
    out = os.environ.get("GITHUB_OUTPUT")
    if not out:
        return
    safe_value = value.replace("\n", "%0A")
    with open(out, "a", encoding="utf-8") as fh:
        fh.write(f"{key}={safe_value}\n")


if __name__ == "__main__":
    sys.exit(main())
