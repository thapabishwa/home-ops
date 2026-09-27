"""Regression tests for the controller's scoring, and for the docs' numbers.

Each incident that changed the scoring has a test that fails on the old
behaviour. The return-time tests pin the figures quoted in
docs/02-routing-and-failover.md, so a change to the constants that moves them
fails here before it reaches the router.

    python3 -m unittest discover -s home-network/tools/replay
"""

import os
import re
import unittest

from controller import Controller, Params, Sample

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "terraform", "scripts", "isp-control.src")

CLEAN = Sample(done=27, failed=0)
DEAD = Sample(done=27, failed=27, up=0)


def run(c, ticks, links, active=0):
    out = None
    for _ in range(ticks):
        out = c.step(links, active)
    return out


def ticks_until(c, links, cond, limit=2000):
    for n in range(1, limit):
        t = c.step(links)
        if cond(t):
            return n
    raise AssertionError("condition never met")


class MatchesRouter(unittest.TestCase):
    def test_constants_match_the_script(self):
        with open(SRC) as f:
            src = f.read()
        p = Params()
        caps = re.search(r':local caps \[:toarray "([\d,]+)"\]', src).group(1)
        self.assertEqual(tuple(int(x) for x in caps.split(",")), p.caps)
        self.assertIn(f":local a {p.a_good}", src)
        self.assertIn(f":set a {p.a_bad}", src)
        self.assertIn(f"$r < {p.yield_below})", src)
        self.assertIn(f"$r > {p.reclaim_above})", src)
        self.assertIn(f":set ispHold {p.hold}", src)
        self.assertIn(f"* {p.margin_pct} / 100", src)


class Reputation(unittest.TestCase):
    def test_bad_tick_costs_thirty_percent(self):
        c = Controller()
        t = c.step([DEAD, CLEAN, CLEAN], active=0)
        self.assertEqual(t.rep[0], 700_000)
        t = c.step([DEAD, CLEAN, CLEAN])
        self.assertEqual(t.rep[0], 490_000)

    def test_no_801_ceiling(self):
        # 2026-09-20: at per-mille, (801*995 + 1000*5)/1000 truncated to 801.
        r = 801
        self.assertEqual((r * 995 + 1000 * 5) // 1000, 801)
        c = Controller(rep=[801_000, 1_000_000, 1_000_000])
        run(c, 400, [CLEAN] * 3)
        self.assertGreater(c.rep[0], 900_000)

    def test_stale_tick_is_not_a_sample(self):
        c = Controller(rep=[600_000, 1_000_000, 1_000_000])
        c.step([Sample(done=0, failed=0), CLEAN, CLEAN], active=0)
        self.assertEqual(c.rep[0], 600_000)

    def test_never_tested_probes_are_not_an_outage(self):
        # 2026-09-28 22:25: an apply recreated all nine probes, all read
        # down@untested, and every link was hard-downed at once.
        c = Controller()
        t = c.step([Sample(done=0, failed=0, up=0, ran=False)] * 3, active=0)
        self.assertEqual(t.hard, [0, 0, 0])
        self.assertEqual(t.rep, [1_000_000] * 3)


class ReturnTimes(unittest.TestCase):
    """docs/02-routing-and-failover.md: a one-tick blip returns in about
    15 min (ISP1 on 26 September took 13.5); 90 s down leaves about 30k and
    needs about 50 min."""

    def test_one_tick_blip(self):
        c = Controller()
        c.step([CLEAN, DEAD, CLEAN], active=0)
        self.assertEqual(c.yielded[1], 1)
        n = ticks_until(c, [CLEAN] * 3, lambda t: t.yielded[1] == 0)
        self.assertTrue(12 * 6 <= n <= 15 * 6, f"{n / 6:.1f} min")

    def test_ninety_seconds_down(self):
        c = Controller()
        run(c, 9, [CLEAN, DEAD, CLEAN])
        self.assertTrue(20_000 <= c.rep[1] <= 45_000, c.rep[1])
        n = ticks_until(c, [CLEAN] * 3, lambda t: t.yielded[1] == 0)
        self.assertTrue(45 * 6 <= n <= 56 * 6, f"{n / 6:.1f} min")


class Selection(unittest.TestCase):
    def test_cold_start_adopts_the_active_route(self):
        c = Controller()
        t = c.step([CLEAN] * 3, active=2)
        self.assertEqual((t.primary, t.why), (2, "adopt"))

    def test_dead_primary_fails_over_at_once(self):
        c = Controller()
        c.step([CLEAN] * 3, active=0)
        t = c.step([DEAD, CLEAN, CLEAN])
        self.assertEqual((t.primary, t.why), (1, "primary-down"))
        self.assertEqual(t.top["via-isp0"], 1)

    def test_quality_promotion_waits_for_hold_and_margin(self):
        c = Controller()
        c.step([CLEAN] * 3, active=2)
        t = run(c, Params().hold - 2, [CLEAN] * 3)
        self.assertEqual(t.primary, 2)
        t = run(c, 2, [CLEAN] * 3)
        self.assertEqual((t.primary, t.why), (0, "sustained-advantage"))

    def test_yielded_big_link_ranks_below_clean_small_one(self):
        # 2026-09-27: ISP0 at 322k (x600) outscored ISP2 at 966k (x200) and
        # took second place two minutes before failing again.
        c = Controller(rep=[322_000, 0, 966_000], yielded=[1, 1, 0], primary=2)
        t = c.step([CLEAN, DEAD, CLEAN])
        self.assertEqual(t.top["via-isp1"], 2)
        self.assertEqual(t.top["via-isp0"], 2)

    def test_tier_hysteresis(self):
        c = Controller(rep=[600_000, 1_000_000, 1_000_000], yielded=[1, 0, 0], primary=1)
        t = c.step([CLEAN] * 3)
        self.assertEqual(t.yielded[0], 1, "600k is between the thresholds: stays yielded")
        c = Controller(rep=[600_000, 1_000_000, 1_000_000], yielded=[0, 0, 0], primary=1)
        t = c.step([CLEAN] * 3)
        self.assertEqual(t.yielded[0], 0, "and stays unyielded coming from above")


if __name__ == "__main__":
    unittest.main()
