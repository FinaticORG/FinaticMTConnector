"""HMAC signing helpers for connector envelopes."""

from __future__ import annotations

import hashlib
import hmac
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

SIGNING_SCHEME_VERSION = 1


def compute_canonical_body(raw_payload: dict[str, Any]) -> bytes:
    """Serialize payload deterministically for signing."""
    return json.dumps(
        raw_payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("utf-8")


def sign_payload(secret_value: str, raw_payload: dict[str, Any]) -> str:
    """Build hexadecimal HMAC-SHA256 signature from canonical body."""
    canonical_body = compute_canonical_body(raw_payload)
    digest = hmac.new(
        key=secret_value.encode("utf-8"),
        msg=canonical_body,
        digestmod=hashlib.sha256,
    )
    return digest.hexdigest()


def verify_payload_signature(
    secret_value: str,
    raw_payload: dict[str, Any],
    signature_value: str,
) -> bool:
    """Verify signature in constant time."""
    expected_signature = sign_payload(secret_value, raw_payload)
    return hmac.compare_digest(expected_signature, signature_value)


@dataclass(frozen=True)
class SigningHeaders:
    """Standardized signing headers for connector transport."""

    x_finatic_sigver: str
    x_finatic_signature: str
    x_finatic_sequence: str
    x_finatic_timestamp: str


def build_signing_headers(
    secret_value: str, raw_payload: dict[str, Any]
) -> SigningHeaders:
    """Build canonical signature headers from payload fields."""
    payload_sequence = str(raw_payload["sequence"])
    payload_timestamp = str(
        raw_payload.get("source_timestamp")
        or datetime.now(tz=UTC).isoformat().replace("+00:00", "Z")
    )
    payload_signature = sign_payload(secret_value, raw_payload)
    return SigningHeaders(
        x_finatic_sigver=str(SIGNING_SCHEME_VERSION),
        x_finatic_signature=payload_signature,
        x_finatic_sequence=payload_sequence,
        x_finatic_timestamp=payload_timestamp,
    )


def extract_signable_body_dictionary(
    *,
    sequence: int,
    secret_version: int,
    platform: str,
    payload: dict[str, Any],
) -> dict[str, Any]:
    """Canonical JSON-compatible dict for EA + Python signing parity."""
    return {
        "payload": payload,
        "platform": platform,
        "secret_version": secret_version,
        "sequence": sequence,
    }


def parse_rfc3339_timestamp_or_raise(timestamp_header_raw: str) -> datetime:
    sanitized_token = timestamp_header_raw.strip().replace("Z", "+00:00")
    normalized_timestamp = datetime.fromisoformat(sanitized_token)
    if normalized_timestamp.tzinfo is None:
        return normalized_timestamp.replace(tzinfo=UTC)
    return normalized_timestamp.astimezone(UTC)


def parse_epoch_seconds_timestamp_or_raise(timestamp_header_raw: str) -> datetime:
    sanitized_token = timestamp_header_raw.strip()
    if not sanitized_token:
        raise ValueError("empty timestamp")
    epoch_seconds = float(sanitized_token)
    return datetime.fromtimestamp(epoch_seconds, tz=UTC)


def parse_finatic_timestamp_header_or_raise(timestamp_header_raw: str) -> datetime:
    """Accept RFC3339 or Unix-epoch seconds from ``X-Finatic-Timestamp``."""
    sanitized_token = timestamp_header_raw.strip()
    if not sanitized_token:
        raise ValueError("empty timestamp")

    if sanitized_token.isdigit() or (
        sanitized_token.replace(".", "", 1).isdigit()
        and sanitized_token.count(".") <= 1
    ):
        return parse_epoch_seconds_timestamp_or_raise(sanitized_token)

    return parse_rfc3339_timestamp_or_raise(sanitized_token)
