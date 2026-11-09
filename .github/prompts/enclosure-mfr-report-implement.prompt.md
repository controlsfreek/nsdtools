---
name: enclosure-mfr-report-implement
description: "Build enclosure-mfr-report from the plan: SSH collect of enclosure *.log files, rename by c/n/r/e, local stats and corrective-action reports. Use when implementing the manufacturing deviation tool."
agent: enclosure-mfr-orchestrator
argument-hint: "Optional focus (collect | analyze | wire CLI)"
---

Implement `enclosure-mfr-report` using [docs/plans/enclosure-mfr-report.md](../../docs/plans/enclosure-mfr-report.md).

Follow locked decisions:

- Bash collect + Python analyze
- Interactive password prompt only (`read -s`, `sshpass -e`, never persist)
- Remote `*.log` under `/opt/fos_deployment/logs/enclosure`
- Rename using `c`, `n`, `r`, `e` from the path
- Outputs: `stats-report.md` and `corrective-action-report.md`

Delegate collect vs analyze vs test to the specialist agents. Do not live-SSH. Run default tests before finishing.

User extra focus: $input
