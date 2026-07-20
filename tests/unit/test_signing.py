from finatic_mt_connector.security.signing import (
    SIGNING_SCHEME_VERSION,
    build_signing_headers,
    sign_payload,
    verify_payload_signature,
)


def test_sign_and_verify_payload_signature_roundtrip() -> None:
    payload = {
        "sequence": 42,
        "source_timestamp": "2026-05-05T18:00:00Z",
        "kind": "events",
    }
    secret_value = "super-secret"

    signature_value = sign_payload(secret_value, payload)

    assert verify_payload_signature(secret_value, payload, signature_value)


def test_build_signing_headers_returns_expected_fields() -> None:
    payload = {
        "sequence": 13,
        "source_timestamp": "2026-05-05T18:00:00Z",
        "kind": "heartbeat",
    }
    headers = build_signing_headers("secret", payload)

    assert headers.x_finatic_sigver == str(SIGNING_SCHEME_VERSION)
    assert headers.x_finatic_sequence == "13"
    assert headers.x_finatic_timestamp == "2026-05-05T18:00:00Z"
    assert len(headers.x_finatic_signature) == 64


def test_parse_finatic_timestamp_header_accepts_epoch_and_rfc3339() -> None:
    from finatic_mt_connector.security.signing import (
        parse_finatic_timestamp_header_or_raise,
    )

    epoch_parsed = parse_finatic_timestamp_header_or_raise("1751284800")
    assert epoch_parsed.year >= 2025
    rfc3339_parsed = parse_finatic_timestamp_header_or_raise(
        "2026-06-30T12:00:00Z"
    )
    assert rfc3339_parsed.isoformat().startswith("2026-06-30")


def test_extract_signable_body_dictionary_matches_background_shape() -> None:
    from finatic_mt_connector.security.signing import (
        extract_signable_body_dictionary,
    )

    signable = extract_signable_body_dictionary(
        sequence=7,
        secret_version=2,
        platform="mt5",
        payload={"event_type": "heartbeat"},
    )
    assert signable == {
        "payload": {"event_type": "heartbeat"},
        "platform": "mt5",
        "secret_version": 2,
        "sequence": 7,
    }
