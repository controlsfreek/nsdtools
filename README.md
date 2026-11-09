# nsdtools

Tools for site and inverter work.

## ECE revisions

`bin/ece-revs.sh` reads enclosure host names from `/etc/dhcp/ansible-enclosure.conf`, keeps hosts that include an enclosure (`e`) field, skips names containing `sw` (switches), sorts them by cluster (`c`), node (`n`), then enclosure (`e`), and SSHes as `root`/`root` to each host's DHCP `fixed-address` IP (30s connect timeout). It lists every host immediately; the rightmost column shows `waiting`, `connecting` (ASCII spinner), `reading`, then the `enclosure-control-engine` version from `apt list --installed`. The table updates in place without scrolling. If the list is taller than the terminal, it uses multiple columns so every host fits on screen, without truncating HOST, IP, or status. SSH queries run in parallel (default 16) and rows stay in c/n/e order.

```bash
./bin/ece-revs.sh
./bin/ece-revs.sh --jobs 16
./bin/ece-revs.sh --conf /etc/dhcp/ansible-enclosure.conf
```

Needs `ssh` and `sshpass`.

## fhm

`bin/fhm` continuously pings static hosts from ISC DHCP configs. It reads `/etc/dhcp/dhcpd.conf` plus files matching `/etc/dhcp/ansible*.conf`. Each `host` block needs a `fixed-address`. OCTE hosts appear first under `[OCTE]`. Other hosts are grouped by core (`c`), then node (`n`), with extra indent for rack (`r`) and enclosure (`e`). Names that do not match that pattern go under `[Unclassified]`.

On a TTY it uses the alternate screen, colors UP green / DOWN red, and paginates when the list is taller than the terminal. The top banner shows the timestamp and the percentage of hosts that are UP (`UP 87% (174/200)`). Left/Right arrows change pages. Ctrl-C stops. Off a TTY it prints a snapshot each interval.

```bash
./bin/fhm
./bin/fhm -i 5 -t 1
./bin/fhm -g '/etc/dhcp/ansible*.conf'
```

Needs `ping` and `awk`.

## enclosure-mfr-report

`bin/enclosure-mfr-report` collects enclosure manufacturing `*.log` files, then writes statistical and corrective-action reports.

- **SSH:** `--host` prompts on a TTY for username (if omitted) and password. The password is not stored, not logged, and cannot be passed as a flag.
- **Offline:** `--from-dir` or `--from-package` skips SSH (used by tests and re-analysis).
- Remote default root: `/opt/fos_deployment/logs/enclosure`. Files are renamed `cCCC_nNNN_rRR_eEE_<basename>` from path tokens. Paths without an `e` token are skipped (`skipped:no-e` in the manifest).

```bash
./bin/enclosure-mfr-report --host 10.0.0.10 --user operator
./bin/enclosure-mfr-report --from-dir tests/fixtures/enclosure_logs --out-dir /tmp/mfr-out
./bin/enclosure-mfr-report --from-package ./package.tar.gz --out-dir ./out --keep-package
```

Outputs in `--out-dir` (default `./var/enclosure-mfr-report/<timestamp>/`): `package/`, `manifest.txt`, `deviations.csv`, `stats-report.md`, `corrective-action-report.md`, `unparsed.txt`.

Requires `python3` and `tar`. SSH mode also needs `ssh` and `sshpass`. Type the password in your own terminal; do not put it in chat, argv, or files.

```bash
bash tests/enclosure_mfr_collect.sh
python3 -m pytest tests/python -q
```

## fos-tui

`bin/fos-tui` is a **read-only** terminal HMI for Fluence OS Sparkplug B traffic. Pure bash (no Python, no `paho-mqtt`). MQTT 3.1.1 over `/dev/tcp`, subscribe-only (no PUBLISH, no last will, no `NCMD`/`DCMD`, no primary host).

It lists MQTT edge nodes as they publish. `↑` `↓` / `j` `k` move, `Enter` opens the HMI for that node type, `Esc` returns to the list, `q` quits.

- **DAC / PCS** (`DAC` in the node name, or a metric containing `inverter01`): EPC M10 inverter screen
- **Core SDU** (`A_C001_SDU` — core token, no node token): CoreSDU heartbeat (`Core_hb`)
- **Node SDU** (`A_C001_N001_SDU` — core and node tokens): NodeSDU screen
- **other**: structure + last seen (no type-specific panel yet)

Sparkplug node names encode site structure (`_` tokens):

- leading letter — array (for example `A`)
- `C` + number — Core
- `N` + number — Node
- `SDU` — Software Dispatch Unit
- `DAC` + number — power conversion system (PCS / inverter)

Examples: `A_C001_N001_SDU`, `A_C001_N001_DAC01`, `A_C001_SDU`, `A_SDU`.

```bash
./bin/fos-tui --demo
./bin/fos-tui
./bin/fos-tui --host 10.0.0.3 --port 1883
./bin/fos-tui --host 10.0.0.3 --port 1883 --device A_C001_N001_DAC01
```

Optional: `--group`, `--node`, `--username`, `--password`, `--client-id`, `--topic`.

Env: `FOS_TUI_MQTT_HOST`, `FOS_TUI_MQTT_PORT`, `FOS_TUI_MQTT_USERNAME`, `FOS_TUI_MQTT_PASSWORD`, `FOS_TUI_MQTT_CLIENT_ID`, `FOS_TUI_SPARKPLUG_GROUP`, `FOS_TUI_SPARKPLUG_NODE`, `FOS_TUI_SPARKPLUG_DEVICE`. Legacy `M10_*` / `CORE_SDU_*` names still work.

`bin/epc-m10-hmi` and `bin/core-sdu-hmi` exec `fos-tui`. Default topic `spBv1.0/#`. Tags stale after 60s.

Subscribe-only inventory dump:

```bash
./tests/list_edge_nodes.sh 127.0.0.1 1883 20
```
