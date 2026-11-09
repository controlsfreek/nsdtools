"""Aggregations for manufacturing-deviation records."""

from __future__ import annotations

from collections import Counter, defaultdict
from statistics import mean, median
from typing import Optional

from enclosure_mfr.c_n_r_e import enclosure_id
from enclosure_mfr.parse import Deviation, Unparsed


def _enc(d: Deviation) -> str:
    return enclosure_id(d.c, d.n, d.r, d.e)


def summarize(
    deviations: list[Deviation],
    unparsed: list[Unparsed],
    file_count: int,
    *,
    top_n: int = 20,
    metadata: Optional[dict] = None,
) -> dict:
    metadata = dict(metadata or {})
    by_code = Counter(d.deviation_code for d in deviations)
    by_sev = Counter(d.severity for d in deviations)
    by_enc = Counter(_enc(d) for d in deviations)
    total = len(deviations)
    unparsed_n = len(unparsed)
    denom = total + unparsed_n
    parse_rate = (total / denom) if denom else 1.0

    top_codes = []
    for code, count in by_code.most_common(top_n):
        top_codes.append(
            {
                "deviation_code": code,
                "count": count,
                "rate": (count / total) if total else 0.0,
            }
        )

    enc_groups: dict[str, list[Deviation]] = defaultdict(list)
    for d in deviations:
        enc_groups[_enc(d)].append(d)

    per_enclosure = []
    for enc, rows in enc_groups.items():
        times = [r.timestamp for r in rows if r.timestamp]
        codes = {r.deviation_code for r in rows}
        per_enclosure.append(
            {
                "enclosure": enc,
                "count": len(rows),
                "distinct_codes": len(codes),
                "first": min(times) if times else "",
                "last": max(times) if times else "",
            }
        )
    per_enclosure.sort(key=lambda x: (-x["count"], x["enclosure"]))

    numeric: dict[str, dict] = {}
    by_code_rows: dict[str, list[Deviation]] = defaultdict(list)
    for d in deviations:
        by_code_rows[d.deviation_code].append(d)
    for code, rows in sorted(by_code_rows.items()):
        actuals = [r.actual for r in rows if r.actual is not None]
        if not actuals:
            continue
        outside = 0
        for r in rows:
            if r.actual is None or r.limit is None:
                continue
            if r.actual > r.limit:
                outside += 1
        numeric[code] = {
            "n": len(actuals),
            "mean": mean(actuals),
            "median": median(actuals),
            "min": min(actuals),
            "max": max(actuals),
            "outside_limit": outside,
        }

    times = [d.timestamp for d in deviations if d.timestamp]
    return {
        "metadata": metadata,
        "file_count": file_count,
        "deviation_count": total,
        "unparsed_count": unparsed_n,
        "parse_success_rate": parse_rate,
        "time_min": min(times) if times else "",
        "time_max": max(times) if times else "",
        "by_code": dict(by_code),
        "by_severity": dict(by_sev),
        "by_enclosure": dict(by_enc),
        "top_codes": top_codes,
        "per_enclosure": per_enclosure,
        "numeric_by_code": numeric,
    }


def corrective_groups(deviations: list[Deviation]) -> list[dict]:
    groups: dict[tuple, list[Deviation]] = defaultdict(list)
    for d in deviations:
        key = (_enc(d), d.deviation_code)
        groups[key].append(d)
    out = []
    for (enc, code), rows in groups.items():
        times = [r.timestamp for r in rows if r.timestamp]
        exemplar = rows[-1].message
        out.append(
            {
                "enclosure": enc,
                "deviation_code": code,
                "count": len(rows),
                "first": min(times) if times else "",
                "last": max(times) if times else "",
                "source_files": sorted({r.source_file for r in rows}),
                "exemplar": exemplar,
                "c": rows[0].c,
                "n": rows[0].n,
                "r": rows[0].r,
                "e": rows[0].e,
            }
        )
    out.sort(key=lambda g: (-g["count"], g["last"], g["enclosure"], g["deviation_code"]))
    return out
