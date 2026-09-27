#!/usr/bin/env python3
"""Replay recorded probe history through the controller and score it.

Answers the question docs/05-decisions.md leaves open: does reputation scoring
put the work tier on better links than probe state alone would have, and do
the constants (30 % / 0.5 %, 500k / 800k, 110 %) earn their keep?

Two sources:

  --prometheus URL   netwatch's cumulative counters at 30 s resolution. The
                     local Prometheus keeps seven days; Grafana Cloud keeps
                     the rest (set PROM_USER and PROM_TOKEN for basic auth).
  --csv FILE...      isp-history.csv and its rotations (plain or .gz), 5-minute
                     loss per link.
                     Each row is spread evenly over 30 ticks, so short events
                     are smeared; use it for chronic loss, not for blips.

Each policy is scored on the work tier (via-isp0):

  moves       times the tier changed link
  bad         ticks on a link losing at least --bad-loss of its probes
  away-clean  ticks off ISP0 while ISP0 itself was clean

    python3 replay.py --prometheus https://prometheus.internal --hours 24
    python3 replay.py --csv isp-history.csv --a-bad 800 --reclaim 700000

Standard library only.
"""

import argparse
import base64
import csv
import gzip
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from dataclasses import replace

from controller import N, Controller, Params, Sample

PROBE_NOMINAL = 27  # tests per link per 10 s tick: three probes at 1 / 1.1 / 1.2 s


def from_prometheus(url, hours, end=None):
    end = end or time.time()
    start = end - hours * 3600
    ctx = ssl.create_default_context()
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE  # household CA
    headers = {}
    if os.environ.get("PROM_USER"):
        tok = f"{os.environ['PROM_USER']}:{os.environ.get('PROM_TOKEN', '')}"
        headers["Authorization"] = "Basic " + base64.b64encode(tok.encode()).decode()

    def series(metric):
        q = (f'sum by (isp) (label_replace({metric}{{name!~"ISP.-cpe"}}, '
             f'"isp", "$1", "name", "(ISP[0-2])-.*"))')
        out = defaultdict(dict)
        # Two-hour requests: a whole day at 30 s is large enough to be cut off.
        for lo in range(int(start), int(end), 7200):
            qs = urllib.parse.urlencode({"query": q, "start": lo, "end": min(lo + 7200, end), "step": 30})
            req = urllib.request.Request(f"{url}/api/v1/query_range?{qs}", headers=headers)
            data = json.load(urllib.request.urlopen(req, context=ctx, timeout=120))
            for r in data["data"]["result"]:
                out[int(r["metric"]["isp"][3])].update(
                    {int(float(t)): float(v) for t, v in r["values"]})
        return out

    done, failed = series("mktxp_netwatch_done_tests"), series("mktxp_netwatch_failed_tests")
    stamps = sorted(set.intersection(*(set(done.get(i, {})) for i in range(N))))

    def delta(s, i, a, b):
        x, y = s[i].get(a), s[i].get(b)
        if x is None or y is None:
            return 0
        return y - x if y >= x else y  # counter reset: reboot or probe edit

    for a, b in zip(stamps, stamps[1:]):
        step = []
        for i in range(N):
            d, f = delta(done, i, a, b), delta(failed, i, a, b)
            step.append((d, f, 0 if d > 0 and f >= d else 3))
        # 30 s between scrapes: three ticks, the deltas split evenly.
        for k in range(3):
            yield b, [Sample(int(d // 3 + (k < d % 3)), int(f // 3 + (k < f % 3)), up)
                      for d, f, up in step]


# isp-log.sh writes a header only when it creates the file, and rotated copies
# have none, so columns are by position.
COLUMNS = ("timestamp", "isp", "probes_up", "probes_total", "loss_pct", "rtt_min_ms",
           "rtt_max_ms", "jitter_ms", "active_isp", "rx_mbps", "tx_mbps")


def load_csv(paths):
    """isp-history.csv and its rotations, plain or gzipped, in any order:
    {timestamp: {isp: (loss_pct, probes_up)}}."""
    rows = defaultdict(dict)
    skipped = 0
    for path in paths:
        opener = gzip.open if path.endswith(".gz") else open
        with opener(path, "rt", errors="replace") as fh:
            for rec in csv.reader(fh):
                if len(rec) != len(COLUMNS) or rec[0] == "timestamp":
                    skipped += 1
                    continue
                r = dict(zip(COLUMNS, rec))
                try:
                    isp, loss, up = int(r["isp"][3]), float(r["loss_pct"]), int(r["probes_up"])
                except (ValueError, IndexError):
                    skipped += 1
                    continue
                rows[r["timestamp"]][isp] = (loss, up)
    if skipped:
        print(f"skipped {skipped} malformed or header lines", file=sys.stderr)
    if rows:
        print(f"history {min(rows)} to {max(rows)}", file=sys.stderr)
    return rows


def sli(rows):
    """The objective's indicator (docs/03-monitoring.md): the share of
    5-minute windows in which at least one link lost under 1 % of probes."""
    windows = [r for r in rows.values() if len(r) == N]
    good = sum(min(loss for loss, _ in r.values()) < 1 for r in windows)
    return len(windows), good


def from_csv(rows):
    for ts in sorted(rows):
        if len(rows[ts]) < N:
            continue
        samples = []
        for i in range(N):
            loss, up = rows[ts][i]
            failed = round(loss / 100 * PROBE_NOMINAL)
            samples.append(Sample(PROBE_NOMINAL, failed, 0 if loss >= 99 and up == 0 else 3))
        for _ in range(30):
            yield ts, samples


def probe_state_only(samples, caps):
    """The rejected alternative: stay on ISP0 unless its probes are all down,
    then take the biggest link that is up. No memory."""
    if samples[0].up > 0:
        return 0
    up = [i for i in range(N) if samples[i].up > 0]
    return max(up, key=lambda i: caps[i]) if up else 0


def score(ticks, params, bad_loss):
    c = Controller(p=params)
    moves = bad = away_clean = 0
    prev = None
    base = {"moves": 0, "bad": 0, "away-clean": 0}
    bprev = None
    n = 0
    for _, s in ticks:
        n += 1
        loss = [x.failed / x.done if x.done else 0.0 for x in s]
        lost = [s[i].up == 0 or loss[i] >= bad_loss for i in range(N)]

        on = c.step(s, active=0).top["via-isp0"]
        moves += prev is not None and on != prev
        bad += lost[on]
        away_clean += on != 0 and not lost[0]
        prev = on

        b = probe_state_only(s, params.caps)
        base["moves"] += bprev is not None and b != bprev
        base["bad"] += lost[b]
        base["away-clean"] += b != 0 and not lost[0]
        bprev = b
    return n, {"moves": moves, "bad": bad, "away-clean": away_clean}, base


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--prometheus", metavar="URL")
    src.add_argument("--csv", metavar="FILE", nargs="+", help="isp-history.csv and rotations, .gz allowed")
    ap.add_argument("--hours", type=float, default=24, help="Prometheus range (default 24)")
    ap.add_argument("--bad-loss", type=float, default=0.02, help="tick loss that counts as bad (default 0.02)")
    p = Params()
    ap.add_argument("--a-good", type=int, default=p.a_good)
    ap.add_argument("--a-bad", type=int, default=p.a_bad)
    ap.add_argument("--yield-below", type=int, default=p.yield_below)
    ap.add_argument("--reclaim", type=int, default=p.reclaim_above)
    ap.add_argument("--hold", type=int, default=p.hold)
    args = ap.parse_args()

    params = replace(p, a_good=args.a_good, a_bad=args.a_bad, yield_below=args.yield_below,
                     reclaim_above=args.reclaim, hold=args.hold)
    if args.prometheus:
        ticks = from_prometheus(args.prometheus, args.hours)
    else:
        rows = load_csv(args.csv)
        n, good = sli(rows)
        if n:
            print(f"SLI: {good} of {n} windows good, {100 * good / n:.3f} % "
                  f"({(n - good) * 5} min without a good link in {n * 5 / 1440:.1f} days)")
        ticks = from_csv(rows)
    n, ctl, base = score(ticks, params, args.bad_loss)
    if not n:
        sys.exit("no data")

    print(f"{n} ticks ({n / 360:.1f} h), work tier, bad = tick loss >= {args.bad_loss:.1%}")
    print(f"{'policy':<22}{'moves':>8}{'bad':>8}{'away-clean':>12}")
    for name, r in (("controller", ctl), ("probe state only", base)):
        print(f"{name:<22}{r['moves']:>8}{r['bad']:>8}{r['away-clean']:>12}")
    print(f"params: {params}")


if __name__ == "__main__":
    main()
