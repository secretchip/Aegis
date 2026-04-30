#!/usr/bin/env python3
"""
Regenerate consumers/advblockingapp.config from the published manifests at
public_block_lists/manifest.json and public_allow_lists/manifest.json.

Replaces the blockListUrls + allowListUrls in the "blocked-all-lists" group
with the current chunk URLs. Other groups and config keys are preserved.
URLs inside the config still reference frozen public_*_lists/... paths.

Run after pipeline/manifest.py.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    config_path = repo_root / "consumers" / "advblockingapp.config"

    if not config_path.exists():
        print(f"ERROR: missing config at {config_path}", file=sys.stderr)
        return 1

    block_manifest_path = repo_root / "public_block_lists" / "manifest.json"
    allow_manifest_path = repo_root / "public_allow_lists" / "manifest.json"
    for p in (block_manifest_path, allow_manifest_path):
        if not p.exists():
            print(f"ERROR: missing manifest at {p}. Run manifest.py first.", file=sys.stderr)
            return 1

    config = json.loads(config_path.read_text(encoding="utf-8"))
    block_manifest = json.loads(block_manifest_path.read_text(encoding="utf-8"))
    allow_manifest = json.loads(allow_manifest_path.read_text(encoding="utf-8"))

    block_urls = [
        {"url": p["url"]} for p in block_manifest["parts"] if p["kind"] == "domains"
    ]
    allow_urls = [
        p["url"] for p in allow_manifest["parts"] if p["kind"] == "domains"
    ]

    target = None
    for group in config.get("groups", []):
        if group.get("name") == "blocked-all-lists":
            target = group
            break

    if target is None:
        print("ERROR: 'blocked-all-lists' group not found in config", file=sys.stderr)
        return 1

    target["blockListUrls"] = block_urls
    target["allowListUrls"] = allow_urls

    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    print(
        f"Updated {config_path}: {len(block_urls)} block URLs, "
        f"{len(allow_urls)} allow URLs"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
