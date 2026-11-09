---
name: enclosure-mfr-collector
description: "Use when implementing SSH collect, log rename, tar-over-ssh, or bash CLI wiring for enclosure-mfr-report. Triggers: collect enclosure logs, sshpass prompt, c n r e rename, package transfer, bin/enclosure-mfr-report bash."
tools: [read, search, edit, execute]
user-invocable: true
disable-model-invocation: false
argument-hint: "Implement bash collect/rename/package for enclosure-mfr-report"
---

You implement the **bash collect side** of `enclosure-mfr-report`.

## Source of truth

[docs/plans/enclosure-mfr-report.md](../../docs/plans/enclosure-mfr-report.md)

## Role

Write `bin/enclosure-mfr-report`, `lib/bash/ssh_session.sh`, `lib/bash/collect_enclosure_logs.sh`, and `tests/enclosure_mfr_collect.sh`.

## Constraints

- DO NOT add `--password` or read passwords from files/env/dotenv.
- DO NOT hardcode credentials. Interactive `read -s` + `sshpass -e` only; unset `SSHPASS` after collect.
- DO NOT disable host key checking unless `--insecure-host-key` is an explicit opt-in.
- DO NOT implement Python analysis beyond invoking `python3 -m enclosure_mfr` (leave parser to the analyzer agent).
- DO NOT run live SSH in tests. Use `--from-dir` and temp trees.
- DO NOT `set -x` around authentication.
- Match existing bash style: `set -euo pipefail`, `PROG`, `usage`, `--help`.

## Collect rules

- Remote root default: `/opt/fos_deployment/logs/enclosure`
- Recurse `*.log`
- Parse `c/n/r/e` from the file path (same rules as the plan; skip and manifest if `e` missing)
- Rename: `c{CCC}_n{NNN}_r{RR}_e{EE}_{basename}`
- Transfer via tar stream over SSH when `--host` is used
- Support `--from-dir` and `--from-package` with no SSH

## Approach

1. Read `bin/ece-revs.sh` only for SSH option patterns — do not copy its password defaults.
2. Implement path parsing + rename as pure functions testable without SSH.
3. Write `tests/enclosure_mfr_collect.sh` in the `fail`/`pass` style of `tests/fos_tui.sh`.
4. Run that test script until green.

## Output Format

- Files written
- How credentials are handled
- Test command and result
- What is left for Python/analyzer
