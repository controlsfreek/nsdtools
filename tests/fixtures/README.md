# Enclosure manufacturing log fixtures

Synthetic tree used until a redacted real sample is available. Layout mimics
`/opt/fos_deployment/logs/enclosure` on a remote host.

## Assumed line formats

1. **ISO-8601**

   `YYYY-MM-DDTHH:MM:SSZ SEVERITY [MFR-nnnn] message [actual=N limit=N]`

2. **Syslog**

   `Mon DD HH:MM:SS host [SEVERITY] [MFR-nnnn] message [actual=N limit=N]`

`SEVERITY` is `INFO`, `WARN`, `ERROR`, or `FAIL`.

A line is a **deviation** when the message body contains a `MFR-` code or one
of: `deviation`, `manufacturing deviation`, `mfr_dev`, `out of spec`, `oos`,
`fail`, `failed`, `limit exceeded`. The leading severity token is not itself
a match (so `FAIL something unexplained` is unparsed, not a deviation).

## Tree

| Path | Tokens | Notes |
|------|--------|-------|
| `c1n2r3e4/run.log` | c=1 n=2 r=3 e=4 | ISO; MFR-0123 torque; one unparsed FAIL |
| `c001/n002/r01/e03/mfg.log` | c=1 n=2 r=1 e=3 | ISO; MFR-0001 voltage |
| `C12_N3_R1_E8/x.log` | c=12 n=3 r=1 e=8 | syslog; MFR-0444 |
| `untagged/orphan.log` | no `e` | collect skips (`skipped:no-e`) |
