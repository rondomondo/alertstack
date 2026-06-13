#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["cryptography"]
# ///

"""Generate a self-signed TLS certificate and key for local development."""

import argparse
import datetime
import ipaddress
import sys
from pathlib import Path

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
except ImportError:
    print(
        "ERROR: 'cryptography' package not found.\n"
        "Install it with:  uv add --dev cryptography",
        file=sys.stderr,
    )
    sys.exit(1)


def generate(domain: str, cert_dir: Path, days: int = 90, wildcard: bool = False) -> tuple[Path, Path]:
    """Generate a self-signed cert and key for domain, writing to cert_dir.

    Args:
        domain: CN / SAN hostname for the certificate.
        cert_dir: Directory to write the .crt and .key files.
        days: Certificate validity period in days.
        wildcard: Also add *.domain as a SAN entry.

    Returns:
        Tuple of (cert_path, key_path).
    """
    cert_dir.mkdir(parents=True, exist_ok=True)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "IE"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "Dublin"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "Dublin"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "BigCompany"),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "ENG"),
        x509.NameAttribute(NameOID.COMMON_NAME, domain),
    ])

    san_entries: list[x509.GeneralName] = [x509.DNSName(domain)]
    if wildcard:
        san_entries.append(x509.DNSName(f"*.{domain}"))
    if domain == "localhost":
        san_entries.append(x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")))

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=days))
        .add_extension(x509.SubjectAlternativeName(san_entries), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )

    cert_path = cert_dir / f"{domain}.crt"
    key_path = cert_dir / f"{domain}.key"

    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )
    )
    key_path.chmod(0o644)

    return cert_path, key_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-d", "--domain", required=True, help="certificate domain / CN")
    parser.add_argument("--cert-dir", default="app/certs", help="output directory for cert + key")
    parser.add_argument("--days", type=int, default=90, help="validity period in days")
    parser.add_argument("--wildcard", action="store_true", help="also add *.domain as a SAN entry")
    args = parser.parse_args()

    cert_path, key_path = generate(
        domain=args.domain,
        cert_dir=Path(args.cert_dir),
        days=args.days,
        wildcard=args.wildcard,
    )
    print(f"cert: {cert_path}")
    print(f"key:  {key_path}")


if __name__ == "__main__":
    main()
