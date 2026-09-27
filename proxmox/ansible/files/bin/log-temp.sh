#!/bin/sh
# Records package temp + fan so a thermal event has a trail, even if
# the shutdown is abrupt enough to lose the tail of the journal.
t=$(sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4); print $4}')
f=$(awk '/^speed/{print $2}' /proc/acpi/ibm/fan 2>/dev/null)
l=$(uptime | sed -E 's/.*load average[s]?: //')
logger -t thermal "package=${t}C fan=${f}rpm load=${l}"
