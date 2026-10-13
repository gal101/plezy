#!/usr/bin/env python3
"""Reject common personal/network data and high-confidence secrets in staged additions."""

from __future__ import annotations

import ipaddress
import re
import subprocess
import sys

PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(f"{prefix}." + "0." * (2 - prefix.count(".")) + f"0/{mask}")
    for prefix, mask in (("10", 8), ("172.16", 12), ("192.168", 16))
)
IPV4 = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
EMAIL = re.compile(r"\b[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})\b", re.IGNORECASE)
WINDOWS_HOME = re.compile(r"\b[A-Z]:[\\/]Users[\\/](?!\*)([^\\/\s\"']+)", re.IGNORECASE)
SECRET_PATTERNS = (
    re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{24,}"),
    re.compile(
        r"(?i)\b(?:password|passwd|client_secret|api[_-]?key|access[_-]?token)"
        r"\b\s*[:=]\s*[\"'][^\"'\s]{12,}[\"']"
    ),
)
SAFE_EMAIL_DOMAINS = {"example.com", "example.org", "example.net", "example.invalid", "users.noreply.github.com"}


def inspect_added_lines(diff: str) -> list[str]:
    findings: list[str] = []
    path = "<staged diff>"
    line_number = 0

    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            continue
        if line.startswith("@@"):
            match = re.search(r"\+(\d+)(?:,\d+)?", line)
            line_number = int(match.group(1)) if match else 0
            continue
        if line.startswith("+") and not line.startswith("+++"):
            content = line[1:]
            location = f"{path}:{line_number}"
            for match in IPV4.finditer(content):
                try:
                    address = ipaddress.ip_address(match.group())
                except ValueError:
                    continue
                if any(address in network for network in PRIVATE_NETWORKS):
                    findings.append(f"{location}: private IPv4 address; use a documentation address")
            for match in EMAIL.finditer(content):
                domain = match.group(1).lower()
                if domain not in SAFE_EMAIL_DOMAINS:
                    findings.append(f"{location}: email address; use a placeholder or GitHub noreply address")
            if WINDOWS_HOME.search(content):
                findings.append(f"{location}: user-specific Windows home path")
            if any(pattern.search(content) for pattern in SECRET_PATTERNS):
                findings.append(f"{location}: possible credential or private key")
            line_number += 1
        elif line.startswith(" "):
            line_number += 1

    return findings


def main() -> int:
    result = subprocess.run(
        ["git", "diff", "--cached", "--no-ext-diff", "--unified=0", "--no-color", "--"],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode:
        print(result.stderr.strip() or "Could not inspect the staged diff.", file=sys.stderr)
        return result.returncode

    findings = inspect_added_lines(result.stdout)
    if findings:
        print("Staged privacy check failed:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        print("Replace owner-specific values with placeholders before committing.", file=sys.stderr)
        return 1

    print("Staged privacy check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
