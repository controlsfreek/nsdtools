from pathlib import Path

from enclosure_mfr.parse import parse_dir, parse_file, parse_line

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "enclosure_logs"


def test_iso_deviation():
    fields, reason = parse_line(
        "2026-01-10T08:00:01Z ERROR MFR-0123 torque out of spec actual=12.5 limit=10.0"
    )
    assert reason is None
    assert fields["deviation_code"] == "MFR-0123"
    assert fields["severity"] == "ERROR"
    assert fields["actual"] == 12.5
    assert fields["limit"] == 10.0


def test_fail_without_tokens_is_unparsed():
    fields, reason = parse_line("2026-01-10T08:00:04Z FAIL something weird happened with no code")
    assert fields is None
    assert reason == "unparsed-fail"


def test_info_skipped():
    fields, reason = parse_line("2026-01-10T08:00:00Z INFO start test")
    assert fields is None
    assert reason == "skip"


def test_fixture_run_log():
    deviations, unparsed = parse_file(FIXTURES / "c1n2r3e4" / "run.log")
    assert [d.deviation_code for d in deviations] == ["MFR-0123", "MFR-0123"]
    assert deviations[0].c == 1 and deviations[0].n == 2 and deviations[0].r == 3 and deviations[0].e == 4
    assert len(unparsed) == 1
    assert "something weird" in unparsed[0].line


def test_parse_dir_counts():
    deviations, unparsed, nfiles = parse_dir(FIXTURES)
    assert nfiles == 4
    codes = sorted(d.deviation_code for d in deviations)
    assert codes == ["MFR-0001", "MFR-0001", "MFR-0123", "MFR-0123", "MFR-0444", "MFR-9999"]
    assert any("something weird" in u.line for u in unparsed)
