---
name: enclosure-mfr-report
description: "Use when editing enclosure-mfr-report, enclosure log collect, manufacturing deviation stats, corrective-action reports, ssh_session.sh, or lib/python/enclosure_mfr. Enforces interactive SSH credentials and fixture-based tests."
applyTo:
  - "bin/enclosure-mfr-report"
  - "lib/bash/ssh_session.sh"
  - "lib/bash/collect_enclosure_logs.sh"
  - "lib/python/enclosure_mfr/**"
  - "tests/enclosure_mfr_collect.sh"
  - "tests/python/**"
  - "tests/fixtures/enclosure_logs/**"
  - "docs/plans/enclosure-mfr-report.md"
---

Follow [docs/plans/enclosure-mfr-report.md](../../docs/plans/enclosure-mfr-report.md).

- Password: TTY `read -s` only. No `--password`, no hardcoded `root`/`root`, no dotenv secrets.
- Collect is bash; analysis is Python 3 with no SSH.
- Rename logs `c{CCC}_n{NNN}_r{RR}_e{EE}_{basename}` from path tokens; skip files without `e` and record them in the manifest.
- Default tests never use the network. Prefer `--from-dir` fixtures.
- Emit both `stats-report.md` and `corrective-action-report.md` plus `unparsed.txt`.
