from pathlib import Path

from enclosure_mfr.parse import parse_dir
from enclosure_mfr.stats import summarize

ROOT = Path(__file__).resolve().parents[2]
# Analyze as if collect already dropped untagged files: use renamed-style subset.
FIXTURES = ROOT / "tests" / "fixtures" / "enclosure_logs"


def test_known_counts():
    deviations, unparsed, nfiles = parse_dir(FIXTURES)
    # Drop orphan (no e) to match collect behavior.
    deviations = [d for d in deviations if d.e is not None]
    summary = summarize(deviations, unparsed, nfiles)
    assert summary["by_code"]["MFR-0123"] == 2
    assert summary["by_code"]["MFR-0001"] == 2
    assert summary["by_code"]["MFR-0444"] == 1
    assert "MFR-9999" not in summary["by_code"]
    assert summary["deviation_count"] == 5
    assert summary["unparsed_count"] >= 1
    assert summary["numeric_by_code"]["MFR-0123"]["outside_limit"] == 2
    encs = {row["enclosure"]: row["count"] for row in summary["per_enclosure"]}
    assert encs["c1/n2/r3/e4"] == 2
    assert encs["c1/n2/r1/e3"] == 2
    assert encs["c12/n3/r1/e8"] == 1
