#!/opt/pdns-intake/venv/bin/python

import argparse
import sys
from pathlib import Path

from intake_ioc import (
    VALID_REASONS,
    VALID_SOURCES,
    VALID_CONFIDENCE,
    normalize_ioc,
    connect_misp,
    search_existing_ioc,
    create_domain_attribute,
    detect_ioc_type,
)


def load_iocs_from_file(path: str) -> list[str]:
    file_path = Path(path)
    if not file_path.exists():
        raise FileNotFoundError(f"Input file not found: {path}")

    values = []
    for line in file_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        values.append(line)
    return values


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Batch intake domains or hostnames into the PDNS MISP registry."
    )
    parser.add_argument("--input-file", required=True, help="Path to file with one IOC per line")
    parser.add_argument("--reason", required=True, choices=sorted(VALID_REASONS))
    parser.add_argument("--source", required=True, choices=sorted(VALID_SOURCES))
    parser.add_argument("--confidence", choices=sorted(VALID_CONFIDENCE))

    args = parser.parse_args()

    try:
        misp, event_id = connect_misp()
        raw_values = load_iocs_from_file(args.input_file)

        total = 0
        created = 0
        existing = 0
        invalid = 0

        for raw_value in raw_values:
            total += 1
            try:
                ioc_type = detect_ioc_type(raw_value)
                value = normalize_ioc(raw_value, ioc_type)
            except Exception as exc:
                print(f"INVALID: {raw_value} | {exc}")
                invalid += 1
                continue

            matches = search_existing_ioc(misp, event_id, value, ioc_type)
            if matches:
                print(f"EXISTS: {value}")
                existing += 1
                continue

            created_attr = create_domain_attribute(
                misp=misp,
                event_id=event_id,
                domain=value,
                ioc_type=ioc_type,
                reason=args.reason,
                source=args.source,
                confidence=args.confidence,
            )
            print(f"CREATED: {value} | Attribute ID: {created_attr.id}")
            created += 1

        print("\nSUMMARY")
        print(f"TOTAL LINES PROCESSED: {total}")
        print(f"CREATED: {created}")
        print(f"ALREADY EXISTS: {existing}")
        print(f"INVALID: {invalid}")

        return 0

    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
