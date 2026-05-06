# AEGIS-DNS

Daily list update
[![Last commit](https://img.shields.io/github/last-commit/secretchip/AEGIS-DNS)](https://github.com/secretchip/AEGIS-DNS/commits/main)
[![License: GPL v3](https://img.shields.io/badge/license-GPL%20v3-blue)](LICENSE)

[![Block domains](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsecretchip%2FAEGIS-DNS%2Frefs%2Fheads%2Fmain%2Fpublic_block_lists%2Fbadge-domains.json)](public_block_lists/manifest.json)
[![Block IPs](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsecretchip%2FAEGIS-DNS%2Frefs%2Fheads%2Fmain%2Fpublic_block_lists%2Fbadge-ips.json)](public_block_lists/manifest.json)
[![Allow domains](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsecretchip%2FAEGIS-DNS%2Frefs%2Fheads%2Fmain%2Fpublic_allow_lists%2Fbadge-domains.json)](public_allow_lists/manifest.json)
[![Allow IPs](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsecretchip%2FAEGIS-DNS%2Frefs%2Fheads%2Fmain%2Fpublic_allow_lists%2Fbadge-ips.json)](public_allow_lists/manifest.json)
[![Pins](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsecretchip%2FAEGIS-DNS%2Frefs%2Fheads%2Fmain%2Fpublic_block_lists%2Fbadge-pins.json)](sources/pins/)
[![Last build](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fsecretchip%2FAEGIS-DNS%2Frefs%2Fheads%2Fmain%2Fpublic_block_lists%2Fbadge-build.json)](https://github.com/secretchip/AEGIS-DNS/actions/workflows/daily-update.yml)

Curated DNS allowlist + blocklist pipeline. Aggregates many public source
lists, validates and deduplicates them, reconciles allow/block conflicts,
and publishes the result as flat text files for use by DNS filters.
The lists powers [`dns.secretchip.net`](https://dns.secretchip.net) and
are equally usable by AdGuard Home, Pi-hole, Unbound, dnsmasq, or any
other host-list-based filter.

## Stats

<!-- stats:start -->
_Last build: **2026-05-06 09:39 UTC**, took 19m 20s._

| List  | Domains                | IPs                    | Chunks (domains / IPs) |
| ----- | ---------------------: | ---------------------: | ---------------------: |
| block | 45,802,356 | 218,984 | 23 / 1 |
| allow | 21,437 | 21 | 1 / 1 |

Manually pinned: **0** block, **0** allow.
<!-- stats:end -->

(_The block above is regenerated automatically by `pipeline/finalize-build.py` at the end of every pipeline run._)

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

## Run the pipeline locally

```sh
bash pipeline/run-all.sh
```

## Contributing

- **Report a false positive:** open an issue or PR.

## License

GPL-3.0 — see [LICENSE](LICENSE).
