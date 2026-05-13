#!/opt/pdns-intake/venv/bin/python

import argparse
import os
import re
import sys
import warnings
from pathlib import Path

from pymisp import PyMISP
from urllib3.exceptions import InsecureRequestWarning

ENV_FILE = "/opt/pdns-intake/env/pdns-intake.env"

VALID_IOC_TYPES = {"domain", "hostname"}

VALID_DECISIONS = {"allow", "block", "review"}

VALID_REASONS = {
    "ads",
    "benign",
    "internal-allow",
    "malware",
    "phishing",
    "spam",
    "tracker",
}

VALID_SOURCES = {
    "dns-observed",
    "external-feed",
    "manual",
    "misp-feed",
    "sandbox",
    "vt",
}

VALID_CONFIDENCE = {"high", "medium", "low"}

DOMAIN_REGEX = re.compile(
    r"^(?=.{1,253}$)(?!-)[a-z0-9.-]+(?<!-)$"
)
LABEL_REGEX = re.compile(r"^[a-z0-9-]{1,63}$")


def load_env_file(path: str) -> None:
    env_path = Path(path)
    if not env_path.exists():
        raise FileNotFoundError(f"Environment file not found: {path}")

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ[key.strip()] = value.strip()


def str_to_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def get_required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value

def detect_ioc_type(value: str) -> str:
    """
    Detect whether a value is a domain or hostname.

    A hostname contains at least 3 labels:
        sub.example.com

    A domain contains 2 labels:
        example.com
    """
    value = value.strip().lower()

    labels = value.split(".")

    if len(labels) >= 3:
        return "hostname"

    return "domain"

def normalize_ioc(value: str, ioc_type: str) -> str:
    value = value.strip().lower().rstrip(".")
    if not value:
        raise ValueError("IOC is empty after normalization")

    if not DOMAIN_REGEX.match(value):
        raise ValueError(f"Invalid {ioc_type} format: {value}")

    labels = value.split(".")
    if len(labels) < 2:
        raise ValueError(f"Invalid {ioc_type}: must contain at least one dot: {value}")

    for label in labels:
        if not label:
            raise ValueError(f"Invalid {ioc_type}: empty label in {value}")
        if not LABEL_REGEX.match(label):
            raise ValueError(f"Invalid {ioc_type}: bad label '{label}' in {value}")
        if label.startswith("-") or label.endswith("-"):
            raise ValueError(f"Invalid {ioc_type}: label starts/ends with hyphen in {value}")

    if ioc_type == "domain":
        if len(labels) != 2:
            raise ValueError(
                f"Invalid domain for this intake mode: '{value}' looks like a hostname/FQDN. "
                f"Use --ioc-type hostname instead."
            )

    elif ioc_type == "hostname":
        if len(labels) < 3:
            raise ValueError(
                f"Invalid hostname for this intake mode: '{value}' looks like a base domain. "
                f"Use --ioc-type domain instead."
            )
    else:
        raise ValueError(f"Unsupported IOC type: {ioc_type}")

    return value


def build_tag_names(reason: str, source: str, confidence: str | None) -> list[str]:
    tags = [
        'pdns:1:decision="review"',
        f'pdns:2:reason="{reason}"',
        f'pdns:3:source="{source}"',
    ]
    if confidence:
        tags.append(f'pdns:4:confidence="{confidence}"')
    return tags


def connect_misp() -> tuple[PyMISP, str]:
    load_env_file(ENV_FILE)

    misp_url = get_required_env("MISP_URL")
    misp_key = get_required_env("MISP_KEY")
    verify_cert = str_to_bool(os.getenv("MISP_VERIFY_CERT", "false"))
    event_id = get_required_env("PDNS_EVENT_ID")

    if not verify_cert:
        warnings.simplefilter("ignore", InsecureRequestWarning)

    misp = PyMISP(misp_url, misp_key, verify_cert)
    return misp, event_id


def search_existing_ioc(misp: PyMISP, event_id: str, value: str, ioc_type: str):
    result = misp.search(
        controller="attributes",
        eventid=event_id,
        type_attribute=ioc_type,
        value=value,
        pythonify=True,
    )

    matches = []
    for attr in result:
        attr_value = getattr(attr, "value", "")
        attr_type = getattr(attr, "type", "")
        if attr_value and attr_value.strip().lower() == value and attr_type == ioc_type:
            matches.append(attr)

    return matches

def get_tag_names(attr) -> list[str]:
    tags = getattr(attr, "Tag", []) or []
    tag_names = []
    for tag in tags:
        name = getattr(tag, "name", "")
        if name:
            tag_names.append(name)
    return sorted(tag_names)

def strip_pdns_tag_group(tag_names: list[str], group_marker: str) -> list[str]:
    """
    Remove all tags belonging to one PDNS group, for example:
    decision="
    reason="
    source="
    confidence="
    """
    return [tag for tag in tag_names if group_marker not in tag]


def build_single_tag(group: str, value: str) -> str:
    if group == "decision":
        return f'pdns:1:decision="{value}"'
    if group == "reason":
        return f'pdns:2:reason="{value}"'
    if group == "source":
        return f'pdns:3:source="{value}"'
    if group == "confidence":
        return f'pdns:4:confidence="{value}"'
    raise ValueError(f"Unsupported PDNS group: {group}")


def build_updated_tag_set(
    current_tags: list[str],
    decision: str | None,
    reason: str | None,
    source: str | None,
    confidence: str | None,
) -> list[str]:
    updated = list(current_tags)

    if decision is not None:
        updated = strip_pdns_tag_group(updated, 'decision="')
        updated.append(build_single_tag("decision", decision))

    if reason is not None:
        updated = strip_pdns_tag_group(updated, 'reason="')
        updated.append(build_single_tag("reason", reason))

    if source is not None:
        updated = strip_pdns_tag_group(updated, 'source="')
        updated.append(build_single_tag("source", source))

    if confidence is not None:
        updated = strip_pdns_tag_group(updated, 'confidence="')
        updated.append(build_single_tag("confidence", confidence))

    return sorted(set(updated))

def update_existing_attribute(
    misp: PyMISP,
    attr,
    decision: str | None,
    reason: str | None,
    source: str | None,
    confidence: str | None,
):
    current_tags = get_tag_names(attr)
    new_tags = build_updated_tag_set(
        current_tags=current_tags,
        decision=decision,
        reason=reason,
        source=source,
        confidence=confidence,
    )

    current_set = set(current_tags)
    new_set = set(new_tags)

    tags_to_remove = sorted(current_set - new_set)
    tags_to_add = sorted(new_set - current_set)

    for tag in tags_to_remove:
        misp.untag(attr, tag)

    for tag in tags_to_add:
        misp.tag(attr, tag, local=True)

    return misp.get_attribute(attr.id, pythonify=True)

def create_domain_attribute(
    misp: PyMISP,
    event_id: str,
    domain: str,
    ioc_type: str,
    reason: str,
    source: str,
    confidence: str | None,
):
    tags = build_tag_names(reason, source, confidence)

    attribute = {
        "type": ioc_type,
        "category": "Network activity",
        "to_ids": False,
        "value": domain,
    }

    created = misp.add_attribute(event_id, attribute, pythonify=True)

    for tag in tags:
        misp.tag(created, tag, local=True)

    return misp.get_attribute(created.id, pythonify=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Safely intake a domain or hostname into the PDNS MISP registry."
    )
    parser.add_argument("--domain", required=True, help="IOC value to intake (domain or hostname)")
    parser.add_argument("--ioc-type", required=True, choices=sorted(VALID_IOC_TYPES))
    parser.add_argument("--reason", choices=sorted(VALID_REASONS))
    parser.add_argument("--source", choices=sorted(VALID_SOURCES))
    parser.add_argument("--confidence", choices=sorted(VALID_CONFIDENCE))
    parser.add_argument("--decision", choices=sorted(VALID_DECISIONS))
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="Inspect an existing domain without creating or updating anything",
    )
    parser.add_argument(
        "--update-existing",
        action="store_true",
        help="Update an existing domain instead of creating a new one",
    )

    args = parser.parse_args()

    try:
        domain = normalize_ioc(args.domain, args.ioc_type)
        misp, event_id = connect_misp()

        existing = search_existing_ioc(misp, event_id, domain, args.ioc_type)

        if args.inspect:
            if not existing:
                print(f"IOC NOT FOUND: {domain}")
                return 0

            print(f"FOUND IOC: {domain}")
            print(f"Found {len(existing)} existing attribute(s) in event {event_id}")
            for attr in existing:
                print(f"- Attribute ID: {attr.id} | Value: {attr.value}")
                for tag_name in get_tag_names(attr):
                    print(f"  TAG: {tag_name}")
            return 0

        if args.update_existing:
            if not existing:
                raise ValueError(
                    f"Cannot update non-existent IOC: {domain}"
                )

            if len(existing) > 1:
                raise ValueError(
                    f"Refusing to update {domain}: multiple attributes already exist"
                )

            if (
                args.decision is None
                and args.reason is None
                and args.source is None
                and args.confidence is None
            ):
                raise ValueError(
                    "At least one of --decision, --reason, --source, --confidence "
                    "must be provided with --update-existing"
                )

            updated = update_existing_attribute(
                misp=misp,
                attr=existing[0],
                decision=args.decision,
                reason=args.reason,
                source=args.source,
                confidence=args.confidence,
            )

            print(f"UPDATED IOC: {domain}")
            print(f"Attribute ID: {updated.id}")
            for tag_name in get_tag_names(updated):
                print(f"TAG: {tag_name}")
            return 0

        if existing:
            print(f"IOC EXISTS: {domain}")
            print(f"Found {len(existing)} existing attribute(s) in event {event_id}")
            for attr in existing:
                print(f"- Attribute ID: {attr.id} | Value: {attr.value}")
            return 0

        if not args.reason or not args.source:
            raise ValueError(
                "--reason and --source are required when creating a new IOC"
            )

        created = create_domain_attribute(
            misp=misp,
            event_id=event_id,
            domain=domain,
            ioc_type=args.ioc_type,
            reason=args.reason,
            source=args.source,
            confidence=args.confidence,
        )

        print(f"CREATED IOC: {domain}")
        print(f"Attribute ID: {created.id}")
        return 0

    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
