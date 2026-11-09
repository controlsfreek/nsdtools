---
name: enclosure-mfr-report-test
description: "Run and fix enclosure-mfr-report tests (bash collect + Python reports) without live SSH."
agent: enclosure-mfr-tester
argument-hint: "Optional failing test name"
---

Verify `enclosure-mfr-report` against [docs/plans/enclosure-mfr-report.md](../../docs/plans/enclosure-mfr-report.md).

Run:

```bash
bash tests/enclosure_mfr_collect.sh
python3 -m pytest tests/python -q
./bin/enclosure-mfr-report --help
```

No live SSH. No credentials. Fix failures without dropping plan assertions.

User extra focus: $input
