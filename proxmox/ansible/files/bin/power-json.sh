#!/bin/sh
# Host power + thermal state as JSON for Homepage's customapi widget.
# Mirrors wan-json.sh on CT 102: build into a temp file, sanity-check it,
# and only then publish, so the dashboard never reads a half-written file.
#
# Proxmox has no node_exporter, so this reads sysfs directly and PUTs the
# result to dash-agent in the cluster (kubernetes/apps/homenet), which serves
# it to Homepage. Was a pct push into the Caddy container (CT 102).

B=/sys/class/power_supply/BAT0
OUT=/run/power.json

r() { cat "$1" 2>/dev/null; }

cap=$(r $B/capacity)
st=$(r $B/status)
ac=$(r /sys/class/power_supply/AC/online)
cyc=$(r $B/cycle_count)
full=$(r $B/energy_full)
des=$(r $B/energy_full_design)
pwr=$(r $B/power_now)

# Derived state reads better on a dashboard than the raw sysfs string:
# "Not charging" is what a healthy capped battery reports, which looks alarming.
if [ "$ac" = "1" ]; then
    case "$st" in
        Charging) state="charging" ;;
        *)        state="on AC" ;;
    esac
else
    state="ON BATTERY"
fi

health=0
[ -n "$full" ] && [ -n "$des" ] && [ "$des" -gt 0 ] 2>/dev/null && health=$(( full * 100 / des ))

temp=$(sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4); print int($4)}')
fan=$(awk '/^speed/{print $2}' /proc/acpi/ibm/fan 2>/dev/null)
[ -z "$temp" ] && temp=0
[ -z "$fan" ] && fan=0

printf '{"charge_pct":%d,"state":"%s","health_pct":%d,"cycles":%d,"draw_w":%.1f,"temp_c":%d,"fan_rpm":%d}\n' \
    "${cap:-0}" "$state" "$health" "${cyc:-0}" "$(echo "${pwr:-0}" | awk '{printf "%.1f", $1/1000000}')" \
    "$temp" "$fan" > "$OUT.tmp" 2>/dev/null

# Publish only if it looks like the real thing.
if [ -s "$OUT.tmp" ] && grep -q '"state"' "$OUT.tmp"; then
    mv "$OUT.tmp" "$OUT"
    curl -sSf -m 5 -T "$OUT" http://dash.internal/power.json 2>&1 \
        | logger -t power-json
else
    rm -f "$OUT.tmp"
fi
