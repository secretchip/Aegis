# AEGIS-DNS

[![Daily list update](https://github.com/secretchip/AEGIS-DNS/actions/workflows/daily-update.yml/badge.svg)](https://github.com/secretchip/AEGIS-DNS/actions/workflows/daily-update.yml)
[![Last commit](https://img.shields.io/github/last-commit/secretchip/AEGIS-DNS)](https://github.com/secretchip/AEGIS-DNS/commits/main)
[![License: GPL v3](https://img.shields.io/badge/license-GPL%20v3-blue)](LICENSE)

Curated DNS allowlist + blocklist pipeline. Aggregates many public source
lists, validates and deduplicates them, reconciles allow/block conflicts,
and publishes the result as flat text files for use by DNS filters.
The lists powers [`dns.secretchip.net`](https://dns.secretchip.net) and
are equally usable by AdGuard Home, Pi-hole, Unbound, dnsmasq, or any
other host-list-based filter.

## Consume the lists

The fastest path is the **manifest** — it lists every part file, line
count, and SHA-256, so you don't have to hardcode chunk filenames that
change with the data.

| Type  | Manifest |
| ----- | -------- |
| Block | <https://raw.githubusercontent.com/secretchip/AEGIS-DNS/refs/heads/main/public_block_lists/manifest.json> |
| Allow | <https://raw.githubusercontent.com/secretchip/AEGIS-DNS/refs/heads/main/public_allow_lists/manifest.json> |

Manifest schema (v1):

```json
{
  "schema_version": 1,
  "generated_at": "2026-04-29T13:35:20Z",
  "type": "block",
  "total_lines": 46063517,
  "parts": [
    {
      "name": "hosts-block-part0.txt",
      "kind": "domains",
      "url": "https://raw.githubusercontent.com/.../hosts-block-part0.txt",
      "lines": 2000000,
      "sha256": "<hex>"
    }
  ]
}
```

Direct URLs are stable (`hosts-{type}-part{N}.txt` for domains,
`ips-{type}-part{N}.txt` for IPv4) but the chunk count changes — always
read the manifest first.

### Bulk downloads via GitHub Releases

For consumers that want a single download instead of N parts, every list
update also publishes a [GitHub Release](https://github.com/secretchip/AEGIS-DNS/releases)
tagged `release-YYYYMMDD` with:

- `aegis-block-lists.tar.gz` — gzipped `public_block_lists/` (domains + ips + manifest)
- `aegis-allow-lists.tar.gz` — gzipped `public_allow_lists/`
- `block-manifest.json`, `allow-manifest.json` — copies of the manifests
- `sha256sums.txt` — sha256 of every release asset

The latest 30 releases are retained; older ones are pruned automatically.

## How it works

```
URL sources        validate +         allow/block        merge +
(per-line URLs) -> normalize    ->    reconcile     ->   chunk     -> manifest + config
                   (Python)          (Python+awk)        (sort -u)
```

A daily GitHub Actions workflow (`.github/workflows/daily-update.yml`)
runs the pipeline at 04:00 UTC, opens a PR with the diff, and (for
scheduled runs only) auto-merges when CI is green.

For details on each pipeline stage, the validator, manual-input policy,
sanity guards, and URL health tracking, see [CLAUDE.md](CLAUDE.md).

## Run the pipeline locally

```sh
bash pipeline/run-all.sh
```

…or stage-by-stage; see [CLAUDE.md](CLAUDE.md).

Dependencies: `bash`, `python3` (stdlib only), standard Linux tools
(`curl`, `awk`, `sort`, `split`, `grep`, `sed`).

## Contributing

- **Add a source:** append the URL to `sources/block_urls.txt`
  or `sources/allow_urls.txt`.
- **Report a false positive:** open an issue or PR.
- **Run the tests:** `python3 pipeline/tests/python/test_validate.py` and
  `bash pipeline/tests/bash/test_reconcile_guard.sh`.

## License

GPL-3.0 — see [LICENSE](LICENSE).
