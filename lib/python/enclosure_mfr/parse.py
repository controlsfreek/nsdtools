"""Table-driven parser for synthetic enclosure manufacturing logs."""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Optional

from enclosure_mfr.c_n_r_e import parse as parse_tokens

ISO_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\s+"
    r"(?P<sev>INFO|WARN|WARNING|ERROR|FAIL|DEBUG)\s+"
    r"(?P<rest>.*)$"
)
SYSLOG_RE = re.compile(
    r"^(?P<ts>[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+"
    r"(?P<host>\S+)\s+"
    r"(?P<rest>.*)$"
)
SEV_IN_REST_RE = re.compile(r"\b(?P<sev>INFO|WARN|WARNING|ERROR|FAIL|DEBUG)\b", re.I)
CODE_RE = re.compile(r"\b(MFR-\d+)\b", re.I)
ACTUAL_RE = re.compile(r"\bactual=([+-]?\d+(?:\.\d+)?)\b", re.I)
LIMIT_RE = re.compile(r"\blimit=([+-]?\d+(?:\.\d+)?)\b", re.I)

# Matched against the message body (not the leading severity token).
DEVIATION_TOKEN_RE = re.compile(
    r"(manufacturing\s+deviation|\bmfr_dev\b|\bdeviation\b|out of spec|\boos\b|"
    r"limit exceeded|\bfailed\b|\bfail\b)",
    re.I,
)

LINE_PATTERNS = (
    ("iso8601", ISO_RE),
    ("syslog", SYSLOG_RE),
)


@dataclass
class Deviation:
    timestamp: str
    severity: str
    deviation_code: str
    message: str
    c: Optional[int]
    n: Optional[int]
    r: Optional[int]
    e: Optional[int]
    source_file: str
    actual: Optional[float] = None
    limit: Optional[float] = None

    def to_row(self) -> dict:
        return asdict(self)


@dataclass
class Unparsed:
    source_file: str
    line_no: int
    line: str
    reason: str


def _severity_from_rest(rest: str, default: str = "") -> tuple[str, str]:
    match = SEV_IN_REST_RE.search(rest)
    if not match:
        return default.upper() if default else "", rest
    sev = match.group("sev").upper()
    if sev == "WARNING":
        sev = "WARN"
    return sev, rest


def _is_deviation_body(body: str) -> bool:
    if CODE_RE.search(body):
        return True
    return bool(DEVIATION_TOKEN_RE.search(body))


def parse_line(line: str) -> tuple[Optional[dict], Optional[str]]:
    """Return (fields, None) or (None, reason). Empty/comment lines are skipped."""
    raw = line.rstrip("\n")
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        return None, "skip"
    for _name, pattern in LINE_PATTERNS:
        match = pattern.match(stripped)
        if not match:
            continue
        gd = match.groupdict()
        rest = gd.get("rest", "")
        sev = gd.get("sev") or ""
        if not sev:
            sev, rest = _severity_from_rest(rest)
        else:
            sev = sev.upper()
            if sev == "WARNING":
                sev = "WARN"
        code_match = CODE_RE.search(rest)
        code = code_match.group(1).upper() if code_match else ""
        actual_m = ACTUAL_RE.search(rest)
        limit_m = LIMIT_RE.search(rest)
        fields = {
            "timestamp": gd["ts"],
            "severity": sev or "INFO",
            "deviation_code": code,
            "message": rest.strip(),
            "actual": float(actual_m.group(1)) if actual_m else None,
            "limit": float(limit_m.group(1)) if limit_m else None,
        }
        if _is_deviation_body(rest):
            if not fields["deviation_code"]:
                fields["deviation_code"] = "UNCODED"
            return fields, None
        if fields["severity"] in ("ERROR", "FAIL"):
            return None, "unparsed-fail"
        return None, "skip"
    if re.search(r"\b(ERROR|FAIL)\b", stripped, re.I):
        return None, "unparsed-fail"
    return None, "skip"


def parse_file(path: Path) -> tuple[list[Deviation], list[Unparsed]]:
    tokens = parse_tokens(str(path).replace("\\", "/"))
    deviations: list[Deviation] = []
    unparsed: list[Unparsed] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for line_no, line in enumerate(text.splitlines(), 1):
        fields, reason = parse_line(line)
        if fields:
            deviations.append(
                Deviation(
                    timestamp=fields["timestamp"],
                    severity=fields["severity"],
                    deviation_code=fields["deviation_code"],
                    message=fields["message"],
                    c=tokens["c"],
                    n=tokens["n"],
                    r=tokens["r"],
                    e=tokens["e"],
                    source_file=path.name,
                    actual=fields["actual"],
                    limit=fields["limit"],
                )
            )
            continue
        if reason == "unparsed-fail":
            unparsed.append(
                Unparsed(
                    source_file=path.name,
                    line_no=line_no,
                    line=line.rstrip("\n"),
                    reason=reason,
                )
            )
    return deviations, unparsed


def parse_dir(package_dir: Path) -> tuple[list[Deviation], list[Unparsed], int]:
    files = sorted(package_dir.rglob("*.log"))
    deviations: list[Deviation] = []
    unparsed: list[Unparsed] = []
    for path in files:
        d, u = parse_file(path)
        deviations.extend(d)
        unparsed.extend(u)
    return deviations, unparsed, len(files)


def iter_rows(deviations: Iterable[Deviation]) -> Iterable[dict]:
    for item in deviations:
        yield item.to_row()
