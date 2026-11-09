from enclosure_mfr.c_n_r_e import format_renamed_log, parse

CASES = [
    ("/opt/fos_deployment/logs/enclosure/c1n2r3e4/run.log", 1, 2, 3, 4),
    ("/opt/fos_deployment/logs/enclosure/c001/n002/r01/e03/mfg.log", 1, 2, 1, 3),
    ("/opt/fos_deployment/logs/enclosure/C12_N3_R1_E8/x.log", 12, 3, 1, 8),
    ("/opt/fos_deployment/logs/enclosure/c1/foo/c2/e3/x.log", 2, None, None, 3),
]


def test_parse_table():
    for path, c, n, r, e in CASES:
        got = parse(path)
        assert got == {"c": c, "n": n, "r": r, "e": e}, path


def test_rename_example():
    tokens = parse("/opt/fos_deployment/logs/enclosure/c001/n002/r01/e03/mfg.log")
    assert format_renamed_log(tokens["c"], tokens["n"], tokens["r"], tokens["e"], "mfg.log") == (
        "c001_n002_r01_e03_mfg.log"
    )


def test_missing_e():
    got = parse("/opt/fos_deployment/logs/enclosure/untagged/orphan.log")
    assert got["e"] is None
