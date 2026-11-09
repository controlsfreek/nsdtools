from pathlib import Path

from enclosure_mfr.parse import parse_dir
from enclosure_mfr.reports import write_all

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "enclosure_logs"
SNIPPETS = ROOT / "tests" / "fixtures" / "expected_reports"


def test_reports_headings_and_snippets(tmp_path):
    deviations, unparsed, nfiles = parse_dir(FIXTURES)
    deviations = [d for d in deviations if d.e is not None]
    write_all(
        tmp_path,
        deviations,
        unparsed,
        nfiles,
        metadata={"host": "fixture", "out_dir": str(tmp_path)},
    )
    stats = (tmp_path / "stats-report.md").read_text(encoding="utf-8")
    corr = (tmp_path / "corrective-action-report.md").read_text(encoding="utf-8")
    unp = (tmp_path / "unparsed.txt").read_text(encoding="utf-8")
    csv = (tmp_path / "deviations.csv").read_text(encoding="utf-8")

    for line in (SNIPPETS / "stats-snippet.txt").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            assert line in stats, line
    for line in (SNIPPETS / "corrective-snippet.txt").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            assert line in corr, line

    assert "something weird happened with no code" in unp
    assert unp.strip()
    assert "MFR-0123" in csv
    assert "password" not in stats.lower()
    assert "Inspect enclosure" in corr or "Inspect torque" in corr
