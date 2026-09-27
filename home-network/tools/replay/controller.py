"""The scoring pass of terraform/scripts/isp-control.src, in Python.

A line-for-line port of the once-every-ten-seconds half of the controller:
reputation, tier yield, primary selection and the ranking that sets route
distances. Integer arithmetic throughout, truncating like RouterOS, because
the 801 ceiling was a truncation bug and a float port would have hidden it.

Not ported: the every-second fast path (it demotes a link whose probes are all
down; the scoring pass reaches the same verdict on its next tick), conntrack
flushes and logging. Replay therefore resolves to one 10 s tick, never to the
2 s failover.

The constants are parameters so a replay can compare them. Defaults are what
runs on the router; test_controller.py fails if the two drift.
"""

from dataclasses import dataclass, field

N = 3
TABLES = ("main", "via-isp0", "via-isp1", "via-isp2")


@dataclass(frozen=True)
class Params:
    caps: tuple = (600, 400, 200)  # `caps` in isp-control.src
    a_good: int = 995              # weight kept on a better sample (0.5 % step)
    a_bad: int = 700               # weight kept on a worse sample (30 % step)
    yield_below: int = 500_000
    reclaim_above: int = 800_000
    hold: int = 90                 # ticks before a quality promotion (15 min)
    margin_pct: int = 110


@dataclass
class Sample:
    """One link over one tick: probe counter deltas and probes up at the end."""
    done: int
    failed: int
    up: int = 3
    ran: bool = True  # at least one probe has ever completed a test


@dataclass
class Tick:
    tick: int
    rep: list
    hard: list
    yielded: list
    primary: int
    top: dict  # table -> ISP index at distance 1
    why: str


@dataclass
class Controller:
    p: Params = field(default_factory=Params)
    rep: list = field(default_factory=lambda: [1_000_000] * N)
    yielded: list = field(default_factory=lambda: [0] * N)
    primary: int = -1
    last_sw: int = 0
    tick: int = 0

    def step(self, s, active=None):
        """One scoring pass. `s` is three Samples; `active` is main's current
        ISP, used only on the cold-start tick, as the script reads it from the
        routing table."""
        p = self.p
        self.tick += 1
        score, hard = [0] * N, [0] * N

        for i in range(N):
            fresh = s[i].done > 0
            l = s[i].failed * 1000 // s[i].done if fresh else 0
            if s[i].up == 0 and s[i].ran:
                hard[i], l, fresh = 1, 1000, True
            r = self.rep[i]
            if fresh:
                q = (1000 - l) * 1000
                a = p.a_bad if q < r else p.a_good
                r = min(max((r * a + q * (1000 - a)) // 1000, 0), 1_000_000)
                self.rep[i] = r
            score[i] = r * p.caps[i] // 1_000_000

        # Best candidate on the PREVIOUS tick's yield, with this tick's
        # hard-down counting as yielded.
        best = 0
        for i in (1, 2):
            yi = 1 if hard[i] else self.yielded[i]
            yb = 1 if hard[best] else self.yielded[best]
            if yi < yb or (yi == yb and score[i] > score[best]):
                best = i

        why = ""
        if self.primary < 0:
            self.primary = best if active is None else active
            self.last_sw, why = self.tick, "adopt"
        elif best != self.primary:
            if hard[self.primary]:
                self.primary, self.last_sw, why = best, self.tick, "primary-down"
            elif self.tick - self.last_sw >= p.hold:
                if score[best] > score[self.primary] * p.margin_pct // 100:
                    self.primary, self.last_sw, why = best, self.tick, "sustained-advantage"
                elif self.yielded[self.primary] == 1 and self.yielded[best] == 0:
                    self.primary, self.last_sw, why = best, self.tick, "primary-yielded"

        for i in range(N):
            if hard[i] or self.rep[i] < p.yield_below:
                self.yielded[i] = 1
            if not hard[i] and self.rep[i] > p.reclaim_above:
                self.yielded[i] = 0

        # Selection sort, as in the script: unyielded first, then by score.
        ordr = [0, 1, 2]
        for a in range(2):
            for b in range(a + 1, 3):
                ia, ib = ordr[a], ordr[b]
                ya, yb = self.yielded[ia], self.yielded[ib]
                if yb < ya or (yb == ya and score[ib] > score[ia]):
                    ordr[a], ordr[b] = ib, ia

        top = {"main": self.primary}
        for t in (1, 2, 3):
            pref = t - 1
            top[TABLES[t]] = pref if self.yielded[pref] == 0 else ordr[0]

        return Tick(self.tick, list(self.rep), hard, list(self.yielded),
                    self.primary, top, why)
