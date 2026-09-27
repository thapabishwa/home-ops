#!/bin/sh
# Detect and record WAN state transitions, and shout about the ones that matter.
#
# Written after 2026-09-23, when two things went unnoticed for hours:
#
#   NTFiber was down for ~4 hours and the first anyone knew was a text message
#   from a DIFFERENT ISP about a DIFFERENT outage.
#
#   The hEX rebooted, the controller re-initialised into shadow mode, and
#   failover was silently disabled for 12.5 hours. The scheduler was running,
#   the log was ticking, every reputation looked healthy. The only tell was one
#   word in a heartbeat line that otherwise reads exactly like a working one.
#
# Both were plainly visible in data nobody was looking at. isp-log.sh samples
# every 5 minutes and is excellent for "what was the loss last Tuesday"; it is
# useless for "tell me now". This is the other half: it holds no history, only
# the previous state, and its whole job is noticing that something changed.
#
# Deliberately separate from isp-log.sh rather than bolted onto it. That script
# keeps counter baselines and must run on a fixed cadence for its deltas to
# mean anything; this one wants to run often and may be restarted or re-armed
# at will. Sharing state between them would corrupt both -- the same lesson as
# wan-json.sh, which already keeps its own baseline for exactly this reason.

. ${CONF_DIR:-/etc}/hex-api.conf
# Optional. Defines NOTIFY_URL (a webhook that accepts the message as the POST
# body -- ntfy.sh and friends) and optionally NOTIFY_TITLE. Absent, events are
# still recorded; only the shouting is lost.
[ -f ${CONF_DIR:-/etc}/isp-watch.conf ] && . ${CONF_DIR:-/etc}/isp-watch.conf

STATE=${STATE_DIR:-/var/lib}/isp-watch-state
EVENTS=${LOG_DIR:-/var/log}/isp-events.log
TS=$(date -Is)
NOW=$(date +%s)

[ -n "$HEX_HOST" ] && [ -n "$HEX_USER" ] && [ -n "$HEX_PASS" ] || {
    logger -t isp-watch "credentials not set"; exit 1; }

api() { curl -s -m 8 -u "$HEX_USER:$HEX_PASS" "http://$HEX_HOST/rest/$1" 2>/dev/null; }

NW=$(api tool/netwatch)
SY=$(api system/resource)
LG=$(api log)
SC=$(api system/script)

# A failed fetch must not look like an outage. Nine probes reported down
# because the router was unreachable would be a false alarm indistinguishable
# from a real one, and a monitor that cries wolf gets muted, which is worse
# than no monitor. Bail and leave the previous state untouched.
[ -n "$NW" ] && [ -n "$SY" ] || {
    logger -t isp-watch "hEX unreachable - no state change recorded"; exit 0; }

# --- derive current state -------------------------------------------------

probes_up() {
    printf '%s' "$NW" | tr '}' '\n' | grep "\"comment\":\"$1-probe\"" \
        | grep -c '"status":"up"'
}
UP0=$(probes_up ISP0); UP1=$(probes_up ISP1); UP2=$(probes_up ISP2)

# An ISP is "healthy" only when every one of its three probes answers. The
# three are independent operators, so anything less is already degraded.
H0=0; [ "$UP0" -eq 3 ] && H0=1
H1=0; [ "$UP1" -eq 3 ] && H1=1
H2=0; [ "$UP2" -eq 3 ] && H2=1
HEALTHY=$((H0 + H1 + H2))

# RouterOS prints uptime as 3d4h5m6s. Converted to seconds so a REBOOT can be
# detected as the counter going backwards -- the only reliable signal, since
# the log buffer rolls over and loses the startup entry within hours.
UPRAW=$(printf '%s' "$SY" | tr ',' '\n' | grep '"uptime"' | sed 's/.*"uptime":"//;s/".*//')
UPSEC=$(printf '%s' "$UPRAW" | awk '{
    d=0;h=0;m=0;s=0
    if (match($0,/[0-9]+d/)) d=substr($0,RSTART,RLENGTH-1)
    if (match($0,/[0-9]+h/)) h=substr($0,RSTART,RLENGTH-1)
    if (match($0,/[0-9]+m/)) m=substr($0,RSTART,RLENGTH-1)
    if (match($0,/[0-9]+s/)) s=substr($0,RSTART,RLENGTH-1)
    print d*86400 + h*3600 + m*60 + s }')

# Controller mode is read from what it SAYS, not from its globals -- the
# environment is not exposed over REST (500), and its own heartbeat is the
# better source anyway: it reports the mode it is actually acting in.
#
# Matched on "ISP-control <MODE>", the heartbeat's own prefix. Every route the
# controller changes also logs a system,info line naming
# "script:ISP-control", with no mode in it; matching the bare name read the
# mode as unknown after each failover (dozens of times from 9 October).
MODE=$(printf '%s' "$LG" | grep -o 'ISP-control \(ENFORCE\|SHADOW\)' | tail -1 \
       | grep -o 'ENFORCE\|SHADOW')
[ -n "$MODE" ] || MODE=unknown

# run-count proves the scheduler is still firing it. A controller that has
# stopped running leaves every route exactly as it last set them, so the
# network looks fine right up until something fails and nothing moves.
RUNS=$(printf '%s' "$SC" | tr '}' '\n' | grep '"name":"ISP-control"' \
       | grep -o '"run-count":"[0-9]*"' | grep -o '[0-9]*')
[ -n "$RUNS" ] || RUNS=0

# --- compare against last known ------------------------------------------

# shellcheck disable=SC2034  # P_H0..2 are read through eval below
P_H0='' P_H1='' P_H2='' P_HEALTHY='' P_MODE='' P_RUNS='' P_UPSEC='' P_TS=''
# shellcheck source=/dev/null  # this script's own state file
[ -f "$STATE" ] && . "$STATE"

[ -f "$EVENTS" ] || echo "# timestamp  severity  event" > "$EVENTS"

emit() {
    sev=$1; shift
    printf '%s  %-6s  %s\n' "$TS" "$sev" "$*" >> "$EVENTS"
    logger -t isp-watch "$sev: $*"
    [ -n "$NOTIFY_URL" ] && curl -s -m 8 \
        -H "Title: ${NOTIFY_TITLE:-homelab WAN}" \
        -H "Priority: $([ "$sev" = CRIT ] && echo urgent || echo default)" \
        -d "$*" "$NOTIFY_URL" >/dev/null 2>&1
    return 0
}

# First run records a baseline without firing. Otherwise arming the watcher
# would announce the entire current state as though it had just happened.
if [ -z "$P_MODE" ]; then
    # Severity reflects what is actually true at the moment of arming, rather
    # than always INFO -- starting the watcher during an outage should not read
    # as a quiet start.
    sev=INFO; [ "$HEALTHY" -le 1 ] && sev=CRIT
    emit "$sev" "watch started - healthy=$HEALTHY/3 mode=$MODE"
else
    for n in 0 1 2; do
        eval "cur=\$H$n"; eval "prev=\$P_H$n"
        # shellcheck disable=SC2154  # assigned by the eval above
        [ "$cur" = "$prev" ] && continue
        if [ "$cur" = 1 ]; then emit INFO "ISP$n recovered"
        else emit WARN "ISP$n DOWN - all three probes failed"; fi
    done

    # The state worth waking up for. One link left is not an outage, so
    # nothing else reports it -- but it means the next failure is an outage,
    # which is precisely when you want warning rather than news.
    if [ "$HEALTHY" != "$P_HEALTHY" ]; then
        case "$HEALTHY" in
          0) emit CRIT "ALL WANS DOWN" ;;
          1) emit CRIT "NO REDUNDANCY - only one healthy WAN left" ;;
          *) [ "$P_HEALTHY" -lt "$HEALTHY" ] && emit INFO "redundancy restored - $HEALTHY/3 healthy" ;;
        esac
    fi

    [ "$MODE" != "$P_MODE" ] && [ "$MODE" = SHADOW ] && \
        emit CRIT "controller NOT ENFORCING - failover is disabled"
    [ "$MODE" != "$P_MODE" ] && [ "$MODE" = ENFORCE ] && \
        emit INFO "controller enforcing again"

    # Equal run-counts means the scheduler is not firing it -- but only if
    # enough time has passed for it to have fired at all. The controller runs
    # every 10s; without this guard, two watcher runs a second apart report a
    # stall that is not there. Caught on the very first test, which is the
    # point: a monitor that cries wolf gets muted, and a muted monitor is worse
    # than none.
    ELAPSED=$((NOW - ${P_TS:-0}))
    [ "$RUNS" = "$P_RUNS" ] && [ "$ELAPSED" -ge 60 ] && \
        emit CRIT "controller STALLED - run-count stuck at $RUNS for ${ELAPSED}s"

    # Uptime going backwards is a reboot. Worth an event of its own because it
    # wipes every reputation the controller has accumulated, and because it is
    # how the controller ended up in shadow mode in the first place.
    [ -n "$P_UPSEC" ] && [ "$UPSEC" -lt "$P_UPSEC" ] && \
        emit WARN "hEX REBOOTED - reputation history reset, verify enforcement"
fi

cat > "$STATE" <<EOF
P_H0=$H0
P_H1=$H1
P_H2=$H2
P_HEALTHY=$HEALTHY
P_MODE=$MODE
P_RUNS=$RUNS
P_UPSEC=$UPSEC
P_TS=$NOW
EOF
