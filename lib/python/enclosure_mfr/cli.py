"""python -m enclosure_mfr — analyze a local package of renamed logs."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from enclosure_mfr.parse import parse_dir
from enclosure_mfr.reports import write_all


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="enclosure_mfr",
        description="Analyze enclosure manufacturing-deviation logs and write reports.",
    )
    p.add_argument("--from-dir", required=True, help="Directory of renamed *.log files")
    p.add_argument("--out-dir", required=True, help="Directory for reports")
    p.add_argument("--host", default="", help="Collection host (metadata only)")
    p.add_argument("--user", default="", help="SSH username (metadata only; never a password)")
    p.add_argument("--remote-root", default="", help="Remote log root (metadata only)")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    src = Path(args.from_dir)
    out = Path(args.out_dir)
    if not src.is_dir():
        print(f"enclosure_mfr: not a directory: {src}", file=sys.stderr)
        return 2
    deviations, unparsed, file_count = parse_dir(src)
    write_all(
        out,
        deviations,
        unparsed,
        file_count,
        metadata={
            "host": args.host,
            "user": args.user,
            "remote_root": args.remote_root,
            "out_dir": str(out),
        },
    )
    return 0
