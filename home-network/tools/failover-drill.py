#!/usr/bin/env python3
"""Time a failover drill from the user's side of the network.

You do the physical part -- pull a CPE, sit on a call. This does the timing:

  * probes the internet every 0.2 s with a fresh TCP connection to 1.1.1.1:443,
    so the gap it reports is what a new connection from this machine saw;
  * asks the same question from the ROUTER once a second, so the gap is split
    into "the router had no path" and "the router had a path and this machine
    still did not". The 2026-09-28 drill needed that split: the controller
    finished at +14.4 s and traffic did not return until +31.4 s, and nothing
    in the failover logic explains the 17 s in between;
  * reports the first success separately from the settled one. The headline gap
    requires SETTLE seconds of unbroken reachability, so a flickering recovery
    reads as a longer outage -- true to experience, but it hides the moment the
    path first came back;
  * polls the hEX's log over REST for the controller's decision lines, so the
    moment ISP-control acted is recorded next to the moment traffic stopped;
  * prints a row for the results table in docs/07-runbooks.md.

Run it on a device whose tier prefers the link you pull -- the work laptop for
ISP0. Pull ISP1 while running it from the work laptop and, correctly, nothing
happens.

    python3 tools/failover-drill.py ISP0
    python3 tools/failover-drill.py ISP0,ISP1       # double failure
    python3 tools/failover-drill.py ISP0 --return   # also time the tier coming back

Router credentials are read from terraform/credentials.hcl, the same file
Terraform uses. Standard library only.
"""

import argparse
import base64
import json
import os
import re
import socket
import sys
import threading
import time
import urllib.request

TARGET = ("1.1.1.1", 443)
PROBE_EVERY = 0.2
PROBE_TIMEOUT = 0.5
LOG_EVERY = 1.0
ROUTER_PROBE_EVERY = 1.0
SETTLE = 30  # seconds of unbroken reachability that count as "recovered"

HERE = os.path.dirname(os.path.abspath(__file__))
CREDS = os.path.join(HERE, "..", "terraform", "credentials.hcl")


def read_creds(path):
    try:
        text = open(path).read()
    except OSError as e:
        sys.exit(f"cannot read {path}: {e}")
    vals = dict(re.findall(r'(router_\w+)\s*=\s*"([^"]*)"', text))
    try:
        return vals["router_url"], vals["router_username"], vals["router_password"]
    except KeyError as e:
        sys.exit(f"{path} has no {e.args[0]}")


class Router:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.auth = f"Basic {token}"
        # The router is on the LAN. Never route it through an HTTP(S)_PROXY from
        # the environment: a proxy can accept the request and hold it, and the
        # drill then stalls instead of failing.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def ping(self, address):
        """One ICMP echo from the router. ICMP rather than TCP because RouterOS
        has no raw connect primitive over REST -- /tool/fetch would put a TLS
        handshake in every sample. 1.1.1.1 answers ICMP reliably (measured 0%
        loss at 10/s on 2026-09-28), unlike Quad9 and OpenDNS which police it."""
        body = json.dumps({"address": address, "count": "1"}).encode()
        req = urllib.request.Request(self.url + "/rest/ping", data=body, method="POST",
                                     headers={"Authorization": self.auth,
                                              "Content-Type": "application/json"})
        with self.opener.open(req, timeout=4) as r:
            return json.load(r)

    def log(self):
        req = urllib.request.Request(self.url + "/rest/log",
                                     headers={"Authorization": self.auth})
        with self.opener.open(req, timeout=3) as r:
            return json.load(r)


class Prober(threading.Thread):
    """Records (local time, reachable) every PROBE_EVERY seconds."""

    def __init__(self):
        super().__init__(daemon=True)
        self.samples = []
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            t = time.time()
            ok = True
            try:
                socket.create_connection(TARGET, timeout=PROBE_TIMEOUT).close()
            except OSError:
                ok = False
            self.samples.append((t, ok))
            self.stop.wait(max(0.0, PROBE_EVERY - (time.time() - t)))


class RouterProbe(threading.Thread):
    """The same question as Prober, asked from the router.

    If the router regains a path while this machine is still dark, the remaining
    time is between the two -- conntrack, srcnat, or the client's own stack --
    and no amount of failover tuning will touch it.
    """

    def __init__(self, router):
        super().__init__(daemon=True)
        self.router = router
        self.samples = []
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            t = time.time()
            ok = False
            try:
                ok = any(int(r.get("received", 0)) > 0 for r in self.router.ping(TARGET[0]))
            except Exception:
                ok = False
            self.samples.append((t, ok))
            self.stop.wait(max(0.0, ROUTER_PROBE_EVERY - (time.time() - t)))


class LogWatch(threading.Thread):
    """Records ISP-control lines as they appear, stamped with local time."""

    def __init__(self, router):
        super().__init__(daemon=True)
        self.router = router
        self.seen = set()
        self.lines = []
        self.errors = 0
        self.stop = threading.Event()

    def poll(self, record=True):
        entries = self.router.log()
        now = time.time()
        for e in entries:
            if e.get(".id") in self.seen:
                continue
            self.seen.add(e.get(".id"))
            if record and ("ISP-control" in e.get("message", "") or
                           "ISP-probe" in e.get("message", "") or
                           "ISP-fastpath" in e.get("message", "")):
                self.lines.append((now, e["message"]))

    def run(self):
        while not self.stop.is_set():
            try:
                self.poll()
            except Exception:
                self.errors += 1
            self.stop.wait(LOG_EVERY)


def outage(samples, since):
    """First failure after `since`, and the first success that starts SETTLE s
    of unbroken reachability after it. Returns (down, up) or None."""
    after = [s for s in samples if s[0] >= since]
    down = next((t for t, ok in after if not ok), None)
    if down is None:
        return None
    for i, (t, ok) in enumerate(after):
        if t <= down or not ok:
            continue
        rest = [s for s in after[i:] if s[0] <= t + SETTLE]
        if rest and all(ok2 for _, ok2 in rest) and rest[-1][0] - t >= SETTLE - 1:
            return down, t
    return down, None


def first_up(samples, down, need=1):
    """First success after `down` that is followed by `need` consecutive
    successes. Unlike outage(), does not demand SETTLE seconds -- this is the
    moment the path came back, not the moment it stayed back."""
    after = [s for s in samples if s[0] > down]
    for i, (t, ok) in enumerate(after):
        if ok and all(o for _, o in after[i:i + need]):
            return t
    return None


def yield_bits(message):
    m = re.search(r"yield=([01]{3})", message)
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("links", help="link(s) to pull, e.g. ISP0 or ISP0,ISP1")
    ap.add_argument("--return", dest="ret", action="store_true",
                    help="after re-plugging, wait for the tier to reclaim its link")
    ap.add_argument("--creds", default=CREDS)
    args = ap.parse_args()

    links = [l.strip().upper() for l in args.links.split(",")]
    if any(l not in ("ISP0", "ISP1", "ISP2") for l in links):
        sys.exit("links must be ISP0, ISP1 or ISP2")

    router = Router(*read_creds(args.creds))
    watch = LogWatch(router)
    try:
        watch.poll(record=False)  # mark the existing buffer as already seen
    except Exception as e:
        sys.exit(f"cannot read the router log at {router.url}: {e}")

    probe = Prober()
    rprobe = RouterProbe(router)
    probe.start()
    rprobe.start()
    watch.start()

    print("Baseline: 10 s of normal traffic...")
    time.sleep(10)
    base = [ok for _, ok in probe.samples]
    if not all(base):
        print(f"warning: {base.count(False)} baseline failures -- the path is not clean")

    input(f"\nPull {' and '.join(links)} now, and press Enter at the moment you do. ")
    t0 = time.time()
    print("Measuring. Waiting for traffic to stop and recover...")

    deadline = t0 + 180
    result = None
    while time.time() < deadline:
        time.sleep(1)
        result = outage(probe.samples, t0)
        if result and result[1]:
            break

    # First ACTION, not the first scoring pass. Until 2026-09-29 this matched
    # only "flush:", which the emergency demotion never emits -- so the 23:57
    # drill reported 6.8 s when the demotion that actually restored traffic had
    # happened at about 1.5 s. Match the fast path first, then the scoring pass.
    def acted_at(pred):
        return next((t for t, m in watch.lines if t >= t0 and pred(m)), None)

    acted = (acted_at(lambda m: "ISP-fastpath" in m)
             or acted_at(lambda m: re.search(r"distance=5[0-9]", m) is not None)
             or acted_at(lambda m: "flush:" in m))

    down, up = result if result else (None, None)
    gap = f"{up - down:.1f}" if down and up else ("none" if not down else ">180")
    # Timed from when traffic actually stopped, not from the keypress: the two
    # differ by however long the hand took to reach the cable.
    detect = f"{acted - down:.1f}" if acted and down else "not seen"
    cfirst = first_up(probe.samples, down, need=3) if down else None
    rfirst = first_up(rprobe.samples, down, need=2) if down else None
    if down:
        print(f"\n  traffic stopped    +{down - t0:.1f} s after Enter")
    if rfirst:
        print(f"  ROUTER had a path  +{rfirst - t0:.1f} s after Enter")
    if cfirst:
        print(f"  first success here +{cfirst - t0:.1f} s after Enter")
    if up:
        print(f"  settled (>{SETTLE}s ok)  +{up - t0:.1f} s after Enter")
    print(f"  traffic gap        {gap} s")
    print(f"  controller acted   {detect} s after traffic stopped")
    # The number that says whether failover tuning can help at all.
    if rfirst and cfirst:
        print(f"  client lag         {cfirst - rfirst:.1f} s "
              f"(router reachable, this machine not -- NOT failover)")
    if rfirst and up:
        print(f"  settling tail      {up - (cfirst or rfirst):.1f} s "
              f"(reachable but not yet stable)")
    if watch.errors:
        print(f"  ({watch.errors} router log polls failed)")

    call = ""
    while call not in ("y", "n", "none"):
        call = input("\nDid the call survive? [y/n/none] ").strip().lower()

    ret = ""
    if args.ret:
        input("Plug the CPE back in, and press Enter when you do. ")
        t1 = time.time()
        idx = int(links[0][-1])
        print("Waiting for the tier to reclaim its link. Expect about 50 min: reputation\n"
              "has to climb back above 800k at 0.5% a tick. Ctrl-C stops early and still\n"
              "prints the results.")
        last_note = t1
        try:
            while time.time() < t1 + 5400:
                if time.time() - last_note >= 60:
                    last_note = time.time()
                    latest = next((m for _, m in reversed(watch.lines)
                                   if m.startswith("ISP-control")), "")
                    rep = re.search(r"rep=([\d/]+)", latest)
                    print(f"  {(time.time() - t1) / 60:4.0f} min  "
                          f"yield={yield_bits(latest) or '?'}  "
                          f"rep={rep.group(1) if rep else '?'} (per-mille; heartbeat every 15 min)")
                back = next((t for t, m in watch.lines if t >= t1 and
                             (b := yield_bits(m)) and b[idx] == "0"), None)
                if back:
                    ret = f"{(back - t1) / 60:.0f} min"
                    break
                time.sleep(5)
            else:
                ret = ">90 min"
        except KeyboardInterrupt:
            ret = f">{(time.time() - t1) / 60:.0f} min (stopped)"
        print(f"  tier returned after {ret}")

    probe.stop.set()
    rprobe.stop.set()
    watch.stop.set()

    print("\nFor docs/07-runbooks.md:\n")
    print(f"| {time.strftime('%Y-%m-%d %H:%M')} | {', '.join(links)} | {gap} | "
          f"{detect} | {call} | {ret or '—'} |")
    print("\nController lines seen during the drill:")
    for t, m in watch.lines:
        if t >= t0:
            print(f"  +{t - t0:6.1f}s  {m}")


if __name__ == "__main__":
    main()
