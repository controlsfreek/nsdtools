"""Code → corrective action stubs. Unknown codes use DEFAULT_ACTION."""

from __future__ import annotations

from typing import Optional

DEFAULT_ACTION = (
    "Inspect enclosure {enclosure}; review log line; correct the failed test step and re-run"
)

ACTIONS = {
    "MFR-0123": "Inspect torque tooling and calibration on enclosure {enclosure}; correct over-limit torque and re-run the manufacturing test",
    "MFR-0001": "Inspect voltage sense wiring and test limits on enclosure {enclosure}; correct out-of-spec voltage and re-run",
    "MFR-0444": "Inspect the failed limit check on enclosure {enclosure}; bring the measured value within limit and re-run",
}


def action_for(code: str, enclosure: str, c=None, n=None, r=None, e=None) -> str:
    template = ACTIONS.get(code, DEFAULT_ACTION)
    if enclosure == "" or enclosure is None:
        enclosure = f"c{c}/n{n}/r{r}/e{e}"
    return template.format(enclosure=enclosure, c=c, n=n, r=r, e=e)
