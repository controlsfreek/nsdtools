"""Parse cluster/node/rack/enclosure tokens from a path. Must match lib/bash/collect_enclosure_logs.sh."""

from __future__ import annotations

import re
from typing import Optional

TOKEN_RE = re.compile(r"([cnre])(\d+)", re.IGNORECASE)
RENAMED_RE = re.compile(r"^c\d+_n\d+_r\d+_e\d+_", re.IGNORECASE)


def parse(path: str) -> dict[str, Optional[int]]:
    """Return c/n/r/e integers. Rightmost token of each letter wins."""
    result: dict[str, Optional[int]] = {"c": None, "n": None, "r": None, "e": None}
    for match in TOKEN_RE.finditer(path):
        letter = match.group(1).lower()
        result[letter] = int(match.group(2), 10)
    return result


def format_renamed_log(
    c: Optional[int],
    n: Optional[int],
    r: Optional[int],
    e: Optional[int],
    basename: str,
) -> str:
    return "c{:03d}_n{:03d}_r{:02d}_e{:02d}_{}".format(
        c or 0, n or 0, r or 0, e or 0, basename
    )


def already_renamed(basename: str) -> bool:
    return bool(RENAMED_RE.match(basename))


def enclosure_id(c: Optional[int], n: Optional[int], r: Optional[int], e: Optional[int]) -> str:
    def part(letter: str, value: Optional[int]) -> str:
        return f"{letter}{value}" if value is not None else f"{letter}?"

    return "/".join(
        (
            part("c", c),
            part("n", n),
            part("r", r),
            part("e", e),
        )
    )
