#!/usr/bin/env python3
"""Temperature-driven ThinkPad fan curve.

Built because two settings both proved wrong for a machine racked in a tight
space with the lid shut:

  - the stock EC curve left the fan at 0 rpm while the package sat at 94C
  - a static level 7 runs 3575 rpm forever, wearing the bearing and pulling
    dust through the heatsink even at 45C idle

This ramps earlier and harder than stock, never stops the fan, and still backs
off when genuinely cool. Hysteresis stops it hunting between levels.
"""
import os, subprocess, sys, time

FAN      = "/proc/acpi/ibm/fan"
POLL     = 10        # seconds
FLOOR    = 2         # never below this - stock going to 0 is what caused the 94C
PANIC    = 88        # above this, go unregulated regardless

# (climb_at, fall_back_at, level) - ~4C hysteresis between the two
STEPS = [
    (  0,   0, 2),
    ( 50,  46, 3),
    ( 57,  53, 4),
    ( 64,  60, 5),
    ( 71,  67, 6),
    ( 78,  74, 7),
]

def package_temp():
    try:
        out = subprocess.run(["sensors"], capture_output=True, text=True, timeout=8).stdout
        for line in out.splitlines():
            if "Package id 0" in line:
                return float(line.split("+")[1].split("°")[0])
    except Exception:
        pass
    return None

def set_fan(cmd):
    try:
        with open(FAN, "w") as f:
            f.write(cmd + "\n")
        return True
    except Exception as e:
        print("fan write failed: %s" % e, file=sys.stderr)
        return False

def log(msg):
    subprocess.run(["logger", "-t", "fan-curve", msg], check=False)

idx = len(STEPS) - 1          # start at max until we have a reading
set_fan("level %d" % STEPS[idx][2])
log("started at level %d pending first reading" % STEPS[idx][2])
last_level = STEPS[idx][2]

while True:
    t = package_temp()
    if t is None:
        # can't read temperature - fail loud and cold, never quiet and hot
        if last_level != 7:
            set_fan("level 7"); log("temp unreadable, forcing level 7")
            last_level = 7
    elif t >= PANIC:
        if last_level != "disengaged":
            set_fan("level disengaged"); log("package %.0fC >= %dC, unregulated" % (t, PANIC))
            last_level = "disengaged"
    else:
        while idx < len(STEPS) - 1 and t >= STEPS[idx + 1][0]:
            idx += 1
        while idx > 0 and t <= STEPS[idx][1]:
            idx -= 1
        lvl = max(STEPS[idx][2], FLOOR)
        if lvl != last_level:
            set_fan("level %d" % lvl)
            log("package %.0fC -> level %d" % (t, lvl))
            last_level = lvl
    set_fan("watchdog 120")   # EC reverts to auto if we die
    time.sleep(POLL)
