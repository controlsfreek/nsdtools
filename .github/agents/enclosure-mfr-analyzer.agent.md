---
name: enclosure-mfr-analyzer
description: "Use when parsing enclosure manufacturing logs, computing deviation statistics, or writing stats/corrective-action reports for enclosure-mfr-report. Triggers: manufacturing deviations, stats-report.md, corrective-action-report.md, lib/python/enclosure_mfr, log parser."
tools: [read, search, edit, execute]
user-invocable: true
argument-hint: "Implement Python parse/stats/reports for enclosure-mfr-report"
---

You implement the **Python analysis side** of `enclosure-mfr-report`.

## Source of truth

[docs/plans/enclosure-mfr-report.md](../../docs/plans/enclosure-mfr-report.md)

## Role

Create `lib/python/enclosure_mfr/` (`parse.py`, `c_n_r_e.py`, `stats.py`, `reports.py`, `actions.py`, `cli.py`) plus fixtures and `tests/python/`.

## Constraints

- DO NOT add SSH or password handling in Python.
- DO NOT require third-party packages unless pytest as a dev test runner.
- DO NOT silently drop unparsed FAIL/ERROR lines — write `unparsed.txt`.
- DO NOT claim a real log schema: start from documented synthetic fixtures (T1). Make the parser table-driven.
- `c_n_r_e` rules MUST match the bash collector (same examples as the plan).
- Reports are Markdown for humans; also emit `deviations.csv`.

## Reports

1. `stats-report.md` — counts, rates, per-enclosure table, time range, parse success.
2. `corrective-action-report.md` — grouped by c/n/r/e then deviation code; where / when / what / what to do; worst first.

## Approach

1. Write fixtures under `tests/fixtures/enclosure_logs/` and `tests/fixtures/README.md`.
2. Red tests first, then parser/stats/reports.
3. `python3 -m enclosure_mfr --from-dir … --out-dir …` must be how bash invokes you (`PYTHONPATH=lib/python`).
4. Run `python3 -m pytest tests/python -q` (or unittest if pytest absent).

## Output Format

- Schema assumptions documented
- Files written
- Tests run and result
- Action-map codes that still use the default stub
