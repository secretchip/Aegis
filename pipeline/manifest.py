#!/usr/bin/env python3
"""
Generate manifest.json files describing the published block + allow lists.

Output (one per type):
    public_block_lists/manifest.json
    public_allow_lists/manifest.json

Schema (v1):
    {
      "schema_version": 1,
      "generated_at": "<ISO-8601 UTC>",
      "type": "block" | "allow",
      "total_lines": <int>,
      "parts": [
        {
          "name":   "hosts-block-part0.txt",
          "kind":   "domains" | "ips",
          "url":    "https://raw.githubusercontent.com/.../<name>",
          "lines":  <int>,
          "sha256": "<hex>"
        },
        ...
      ]
    }

Downstream consumers (e.g. dns.secretchip.net) should read the manifest
rather than hardcoding chunk filenames — chunk count varies by run.
"""
from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

# Stable URL prefix for raw GitHub content.
REPO_BASE_URL = "https://raw.githubusercontent.com/secretchip/AEGIS-DNS/refs/heads/main"

PART_GLOBS = {
    "domains": "hosts-{type}-part*.txt",
    "ips": "ips-{type}-part*.txt",
}


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def count_lines(path: Path) -> int:
    """Count *content* lines — skip '#' header lines and blank lines."""
    n = 0
    with path.open("rb") as fh:
        for line in fh:
            stripped = line.lstrip()
            if not stripped or stripped.startswith(b"#"):
                continue
            n += 1
    return n


def build_manifest(repo_root: Path, type_: str) -> dict:
    parts: list[dict] = []
    total = 0
    for kind, glob in PART_GLOBS.items():
        kind_dir = repo_root / f"public_{type_}_lists" / kind
        if not kind_dir.is_dir():
            continue
        for path in sorted(kind_dir.glob(glob.format(type=type_))):
            lines = count_lines(path)
            parts.append({
                "name": path.name,
                "kind": kind,
                "url": f"{REPO_BASE_URL}/public_{type_}_lists/{kind}/{path.name}",
                "lines": lines,
                "sha256": sha256_of(path),
            })
            total += lines

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "type": type_,
        "total_lines": total,
        "parts": parts,
    }


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    for type_ in ("block", "allow"):
        manifest = build_manifest(repo_root, type_)
        out_path = repo_root / f"public_{type_}_lists" / "manifest.json"
        out_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(
            f"{out_path}: {len(manifest['parts'])} parts, "
            f"{manifest['total_lines']:,} total lines"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
