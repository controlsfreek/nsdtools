# Plan: `enclosure-mfr-report`

Agent-executable plan to build and test a new NSDTools CLI that:

1. Logs into a remote host over SSH using **manually entered** credentials (password never stored).
2. Collects `*.log` files under `/opt/fos_deployment/logs/enclosure`.
3. Renames each file using cluster/node/rack/enclosure (`c`, `n`, `r`, `e`) parsed from its **path**.
4. Transfers a data package to localhost.
5. Analyzes manufacturing-deviation content in those logs.
6. Emits a **statistical** report and a **corrective-action** report for people who must find and fix the issues that existed when the tests ran.

This document is the source of truth for Copilot agents. Execute it in order. Do not skip tests. Do not invent live-server credentials or commit secrets.

## Decisions (locked)

| Item | Decision |
|------|----------|
| CLI name | `enclosure-mfr-report` |
| Collect stack | Bash (`bin/` + `lib/bash/`) |
| Analyze stack | Python 3 (`lib/python/enclosure_mfr/`) |
| Remote root | `/opt/fos_deployment/logs/enclosure` |
| File filter | `*.log` (recursive) |
| Rename rule | `c{C}_n{N}_r{R}_e{E}_{original_basename}` using integers from the file path |
| SSH auth | Interactive prompt; password via `read -s`; `sshpass -e` for the session only |
| Hardcoded passwords | Forbidden (do **not** copy `bin/ece-revs.sh` `root`/`root`) |
| Live SSH in CI/unit tests | Forbidden; use fixtures and `--from-dir` |
| Open item | Exact log line schema for “manufacturing deviations” (see spike T1) |

## Why this split

Existing tools (`fos-tui`, `ece-revs.sh`) are bash. Statistical summaries and two human reports are a poor fit for awk-only code. Keep SSH/collect in bash so it matches the repo; keep parsing/stats/reports in a small Python package that tests can run without a network.

## Repository layout (target)

```
bin/enclosure-mfr-report              # CLI orchestrator (bash)
lib/bash/ssh_session.sh               # prompt + ssh/sshpass helpers (no secret persistence)
lib/bash/collect_enclosure_logs.sh    # remote find, rename, tar-over-ssh, unpack
lib/python/enclosure_mfr/
  __init__.py
  parse.py                            # log → deviation records
  c_n_r_e.py                          # path token parser (must match bash)
  stats.py                            # aggregations
  reports.py                          # markdown (+ optional csv) writers
  cli.py                              # python -m enclosure_mfr
tests/enclosure_mfr_collect.sh        # bash collect/rename tests (local tree)
tests/python/test_c_n_r_e.py
tests/python/test_parse.py
tests/python/test_stats.py
tests/python/test_reports.py
tests/fixtures/enclosure_logs/        # synthetic remote tree
tests/fixtures/expected_reports/      # golden markdown snippets
docs/plans/enclosure-mfr-report.md    # this file
```

Optional later: `requirements-dev.txt` with `pytest` only. No runtime Python deps unless T1 proves a parser library is required.

## CLI contract

```bash
./bin/enclosure-mfr-report --host HOST [--user USER] [--port 22]
./bin/enclosure-mfr-report --from-dir DIR
./bin/enclosure-mfr-report --from-package FILE.tar.gz
```

Required behavior:

- `--host`: prompt for username if `--user` omitted; always prompt for password on a TTY (`read -s`). Refuse to take password from argv, env files, or gitignored dotenv (this tool is explicitly manual-entry).
- `--from-dir` / `--from-package`: skip SSH. Used by tests and for re-analysis of an already collected package.
- `--out-dir DIR`: default `./var/enclosure-mfr-report/<timestamp>/`.
- `--remote-root`: default `/opt/fos_deployment/logs/enclosure`.
- `--keep-package`: leave `logs.tar.gz` (or renamed logs dir) in `--out-dir`.
- Exit `0` on success with reports written; non-zero on SSH failure, missing remote root, or analyzer error.
- Never print the password. Never write it to logs, status files, or report metadata.

Outputs in `--out-dir`:

| File | Audience |
|------|----------|
| `package/…` | Collected, renamed `*.log` |
| `manifest.txt` | Source path → renamed file, c/n/r/e, size, mtime |
| `deviations.csv` | Normalized records for further analysis |
| `stats-report.md` | Statistical manufacturing-deviation report |
| `corrective-action-report.md` | Location + what to fix + when it was observed |
| `unparsed.txt` | Lines/files the parser did not understand (must not be silent) |

## Collect pipeline

1. Validate local tools: `bash`, `ssh`, `sshpass`, `tar`, `python3`.
2. Prompt credentials; export `SSHPASS` only in the collect process environment.
3. Remote probe: `test -d "$REMOTE_ROOT"`.
4. Remote staging in `mktemp -d`:
   - `find "$REMOTE_ROOT" -type f -name '*.log'`
   - For each path, parse `c/n/r/e` from the **full path** (directory names and filename). Reuse the same token rules as [`bin/ece-revs.sh`](../../bin/ece-revs.sh) `parse_c_n_r_e`, but **do not require** an `e` token to exist in a hostname — extract whatever tokens are present in the path. If `e` is missing, skip the file and record it in the manifest as `skipped:no-e`.
   - Copy to staging as `c${C}_n${N}_r${R}_e${E}_${basename}` (zero-pad C/N to 3, R/E to 2 unless T1 finds a site convention otherwise). Collision: append `__2`, `__3`, …
5. Stream package to localhost (preferred, one auth):

   ```bash
   ssh … "tar -C \"$stage\" -czf - ." > "$out/package.tar.gz"
   ```

   Do not `scp` a password. Do not use `StrictHostKeyChecking=no` unless `--insecure-host-key` is explicitly passed (default: use the user’s known_hosts).
6. Unset `SSHPASS`. Unpack to `$out/package/`.
7. Invoke Python analyzer on `$out/package`.

SSH options (secure defaults):

- `ConnectTimeout=30`
- `NumberOfPasswordPrompts=1`
- `PreferredAuthentications=password`
- `PubkeyAuthentication=no` for this interactive-password mode
- `LogLevel=ERROR`
- Do **not** disable host key checking by default.

## `c/n/r/e` parsing (shared rule)

Implement identically in bash and Python (tests must compare both).

Scan the path (and basename) for:

- `c` / `C` + digits → cluster
- `n` / `N` + digits → node
- `r` / `R` + digits → rack
- `e` / `E` + digits → enclosure

Examples that must work:

| Path | Result |
|------|--------|
| `/opt/fos_deployment/logs/enclosure/c1n2r3e4/run.log` | c=1 n=2 r=3 e=4 |
| `/opt/fos_deployment/logs/enclosure/c001/n002/r01/e03/mfg.log` | c=1 n=2 r=1 e=3 |
| `/opt/fos_deployment/logs/enclosure/C12_N3_R1_E8/x.log` | c=12 n=3 r=1 e=8 |

Rename example: `c001_n002_r01_e03_mfg.log`.

If multiple tokens of the same letter appear, use the **rightmost** (closest to the file).

## Analysis (Python)

### T1 — log schema spike (first coding task)

The repo has no sample enclosure manufacturing logs. Before writing production regexes:

1. Add `tests/fixtures/enclosure_logs/` with a **documented synthetic** tree and comments in `tests/fixtures/README.md` describing assumed line formats.
2. Parser must be table-driven so real samples can be added later without rewriting reports.
3. If the user later provides a real redacted log, replace fixtures; keep tests green.

**Assumed record fields** (synthetic until real samples exist):

- `timestamp` (ISO-8601 or syslog)
- `severity` (`INFO`/`WARN`/`ERROR`/`FAIL` or equivalent)
- `deviation_code` (stable id, e.g. `MFR-0123` or test step name)
- `message`
- `c,n,r,e` (from filename/path, not necessarily the line)
- `source_file`

Treat as a deviation when the line matches one of:

- explicit tokens: `deviation`, `manufacturing deviation`, `mfr_dev`, `out of spec`, `oos`, `fail`, `failed`, `limit exceeded`
- or a captured `deviation_code`

Non-matching lines are ignored for stats but a sample of unrecognized `ERROR`/`FAIL` lines goes to `unparsed.txt`.

### Statistical report (`stats-report.md`)

Must include:

- Collection metadata: host (if any), remote root, local out-dir, time range min/max, file count, parse success rate
- Counts by `deviation_code`, severity, and enclosure (`c/n/r/e`)
- Top N codes (default 20) with rate vs total deviations
- Per-enclosure table: deviation count, distinct codes, first/last timestamp
- If numeric limit/actual values appear in fixtures, include mean/median/min/max and count outside limits **by code**
- No password, no raw SSH banners

### Corrective-action report (`corrective-action-report.md`)

Written for a technician on the floor / at the rack:

- Group by enclosure (`c/n/r/e`), then by `deviation_code`
- For each group: **where** (c/n/r/e + source log name), **when** (first/last/count), **what failed** (message exemplar), **what to do** (action stub from a small code→action map in `lib/python/enclosure_mfr/actions.py`, defaulting to “Inspect enclosure C/N/R/E; review log line; correct the failed test step and re-run”)
- Sort worst-first (highest count, then most recent)
- Include a “needs human review” section for unparsed FAIL/ERROR lines

## Testing strategy (agents must implement and run)

No live SSH in default tests.

### Bash (`tests/enclosure_mfr_collect.sh`)

- Build a temp tree mirroring `REMOTE_ROOT` with nested and flat c/n/r/e paths, plus a file that cannot be tagged (expect skip).
- Source collect functions with a fake `ssh` not required: test rename/manifest on `--from-dir`.
- Collision renaming.
- CLI `--help` exits 0.
- Password not accepted via `--password` (flag must not exist).

### Python (`pytest tests/python`)

- `c_n_r_e` cases in the table above.
- Parser: fixture logs produce expected CSV rows.
- Stats: known counts.
- Reports: required headings exist; enclosure identifiers appear; golden substring checks.
- `unparsed.txt` non-empty when fixture includes a junk FAIL line.

### Manual / optional live check (not in default test)

Document in README: operator run against a real host. Agents must not attempt this unless the user provides a host in chat **and** types the password into their own terminal (agents must not prompt-relay secrets through the model).

### Validation commands

```bash
# from repo root
bash tests/enclosure_mfr_collect.sh
python3 -m pytest tests/python -q
```

If `pytest` is missing, tests may call `python3 -m unittest` instead; prefer pytest if adding `requirements-dev.txt`.

## Security requirements (non-negotiable)

- Credentials: TTY prompt only; `read -s`; unset after collect.
- Do not log `SSHPASS`, do not `set -x` around sshpass, do not echo remote command lines that might contain secrets.
- Do not add `--password` CLI flags.
- Do not copy `ece-revs.sh` password defaults.
- Reports may include hostname and username, never the password.
- Fixtures must not contain customer PII or real site credentials.

## Agent execution order

Use the Copilot agents/prompts in `.github/`. Do not implement the entire tool in one undifferentiated dump.

| Step | Owner | Done when |
|------|--------|-----------|
| T0 | Orchestrator | Layout exists; this plan still accurate |
| T1 | Analyzer | Fixture README + parser table + failing tests written (red) |
| T2 | Collector | Bash collect/rename/package + `tests/enclosure_mfr_collect.sh` green |
| T3 | Analyzer | Parser/stats/reports + pytest green; CLI calls Python |
| T4 | Collector | `bin/enclosure-mfr-report` wires prompt → collect → analyze |
| T5 | Tester | Full default tests green; no secret flags; README section added |
| T6 | Orchestrator | Plan checklist ticked; leftover TODOs listed |

Each agent returns a short report: files touched, tests run, leftovers.

## Out of scope

- Changing `ece-revs.sh` hardcoded credentials
- MQTT / fos-tui work
- Writing collected logs back to the server
- Auto-remediation on the enclosure
- Storing SSH passwords in Keychain/files

## README snippet (T5)

Add a section to [README.md](../../README.md): purpose, `--host` vs `--from-dir`, credential prompt, output files, test commands, requires `ssh`, `sshpass`, `python3`.
