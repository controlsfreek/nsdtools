"""Write CSV and Markdown reports."""

from __future__ import annotations

import csv
from pathlib import Path

from enclosure_mfr.actions import action_for
from enclosure_mfr.parse import Deviation, Unparsed
from enclosure_mfr.stats import corrective_groups, summarize

CSV_FIELDS = [
    "timestamp",
    "severity",
    "deviation_code",
    "message",
    "c",
    "n",
    "r",
    "e",
    "source_file",
    "actual",
    "limit",
]


def write_csv(path: Path, deviations: list[Deviation]) -> None:
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for d in deviations:
            writer.writerow(d.to_row())


def write_unparsed(path: Path, unparsed: list[Unparsed]) -> None:
    lines = []
    for u in unparsed:
        lines.append(f"{u.source_file}:{u.line_no}: {u.reason}: {u.line}")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def _pct(rate: float) -> str:
    return f"{rate * 100:.1f}%"


def write_stats_report(path: Path, summary: dict) -> None:
    md = summary["metadata"]
    lines = [
        "# Statistical manufacturing-deviation report",
        "",
        "## Collection metadata",
        "",
        f"- Host: {md.get('host') or '—'}",
        f"- User: {md.get('user') or '—'}",
        f"- Remote root: {md.get('remote_root') or '—'}",
        f"- Local out-dir: {md.get('out_dir') or '—'}",
        f"- File count: {summary['file_count']}",
        f"- Deviation records: {summary['deviation_count']}",
        f"- Unparsed FAIL/ERROR lines: {summary['unparsed_count']}",
        f"- Parse success rate: {_pct(summary['parse_success_rate'])}",
        f"- Time range: {summary['time_min'] or '—'} .. {summary['time_max'] or '—'}",
        "",
        "## Counts by deviation code",
        "",
        "| Code | Count |",
        "| --- | ---: |",
    ]
    for code, count in sorted(summary["by_code"].items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append(f"| {code} | {count} |")
    lines += [
        "",
        "## Counts by severity",
        "",
        "| Severity | Count |",
        "| --- | ---: |",
    ]
    for sev, count in sorted(summary["by_severity"].items()):
        lines.append(f"| {sev} | {count} |")
    lines += [
        "",
        "## Top deviation codes",
        "",
        "| Code | Count | Rate |",
        "| --- | ---: | ---: |",
    ]
    for row in summary["top_codes"]:
        lines.append(
            f"| {row['deviation_code']} | {row['count']} | {_pct(row['rate'])} |"
        )
    lines += [
        "",
        "## Per-enclosure",
        "",
        "| Enclosure | Count | Distinct codes | First | Last |",
        "| --- | ---: | ---: | --- | --- |",
    ]
    for row in summary["per_enclosure"]:
        lines.append(
            f"| {row['enclosure']} | {row['count']} | {row['distinct_codes']} | {row['first']} | {row['last']} |"
        )
    lines += [
        "",
        "## Numeric limits by code",
        "",
        "| Code | N | Mean | Median | Min | Max | Outside limit |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    numeric = summary.get("numeric_by_code") or {}
    if not numeric:
        lines.append("| — | 0 | — | — | — | — | 0 |")
    else:
        for code, st in numeric.items():
            lines.append(
                "| {code} | {n} | {mean:.3f} | {median:.3f} | {min:.3f} | {max:.3f} | {outside_limit} |".format(
                    code=code, **st
                )
            )
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_corrective_report(
    path: Path,
    deviations: list[Deviation],
    unparsed: list[Unparsed],
) -> None:
    groups = corrective_groups(deviations)
    lines = [
        "# Corrective action report",
        "",
        "Grouped by enclosure then deviation code. Worst (highest count, then most recent) first.",
        "",
    ]
    if not groups:
        lines += ["No parsed manufacturing deviations.", ""]
    for g in groups:
        files = ", ".join(g["source_files"])
        act = action_for(g["deviation_code"], g["enclosure"], g["c"], g["n"], g["r"], g["e"])
        lines += [
            f"## {g['enclosure']} — {g['deviation_code']}",
            "",
            f"- **Where:** {g['enclosure']} (log: {files})",
            f"- **When:** first {g['first'] or '—'}; last {g['last'] or '—'}; count {g['count']}",
            f"- **What failed:** {g['exemplar']}",
            f"- **What to do:** {act}",
            "",
        ]
    lines += [
        "## Needs human review",
        "",
    ]
    if not unparsed:
        lines.append("No unparsed FAIL/ERROR lines.")
        lines.append("")
    else:
        lines.append("Unparsed FAIL/ERROR lines the parser did not classify as deviations:")
        lines.append("")
        for u in unparsed:
            lines.append(f"- `{u.source_file}:{u.line_no}` {u.line}")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def write_all(
    out_dir: Path,
    deviations: list[Deviation],
    unparsed: list[Unparsed],
    file_count: int,
    metadata: dict,
) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    summary = summarize(deviations, unparsed, file_count, metadata=metadata)
    write_csv(out_dir / "deviations.csv", deviations)
    write_unparsed(out_dir / "unparsed.txt", unparsed)
    write_stats_report(out_dir / "stats-report.md", summary)
    write_corrective_report(out_dir / "corrective-action-report.md", deviations, unparsed)
    return summary
