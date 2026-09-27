#!/bin/sh
# Append a per-ISP health sample to a history file.
#
# Written during the Worldlink degradation of 2026-09-19 (ONT receive power
# -31 then -32 dBm against a -28 threshold, 4-8% loss, 600 Mbps line carrying
# ~200). The point is to keep the incident rather than watch it go past: the
# ranking logic that will eventually pick the default ISP has to be validated
# against a real fault, and there was no record of one.
#
# Deliberately independent of wan-json.sh. That script keeps its own delta
# state for the dashboard, and two consumers differencing the same counters
# would corrupt each other -- each poll resets the baseline for the other.
# This keeps a separate state file and its own cadence.
#
# Loss is computed over the interval between samples, not since boot. A link
# that was down for hours reads near 100 percent lifetime long after it
# recovers, which is useless for judging current health.

. ${CONF_DIR:-/etc}/hex-api.conf

OUT=${LOG_DIR:-/var/log}/isp-history.csv
# Everything logged here must be obtainable identically for every ISP. Vendor
# specifics (ONT optical power, PPPoE session state) are deliberately excluded:
# only one of the three links would ever report them, so they cannot be
# compared and cannot feed a ranking decision.
STATE=${STATE_DIR:-/var/lib}/isp-log-state
NW=$(mktemp)
IF=$(mktemp)
trap 'rm -f "$NW" "$IF"' EXIT

[ -n "$HEX_HOST" ] && [ -n "$HEX_USER" ] && [ -n "$HEX_PASS" ] || {
    logger -t isp-log "credentials not set"; exit 1; }

curl -s -m 8 -u "$HEX_USER:$HEX_PASS" \
     "http://$HEX_HOST/rest/tool/netwatch" > "$NW" 2>/dev/null
ACTIVE=$(curl -s -m 8 -u "$HEX_USER:$HEX_PASS" \
     "http://$HEX_HOST/rest/ip/route?dst-address=0.0.0.0/0" 2>/dev/null \
     | tr "}" "\n" | grep '"active":"true"' | grep '"routing-table":"main"' \
     | grep -oE 'ISP[0-9]' | head -1)
[ -n "$ACTIVE" ] || ACTIVE=none
curl -s -m 8 -u "$HEX_USER:$HEX_PASS" \
     "http://$HEX_HOST/rest/interface" > "$IF" 2>/dev/null
[ -s "$NW" ] || { logger -t isp-log "REST fetch failed"; exit 1; }

P0D=0; P0F=0; P1D=0; P1F=0; P2D=0; P2F=0
B0R=0; B0T=0; B1R=0; B1T=0; B2R=0; B2T=0; TPREV=0
# shellcheck source=/dev/null  # this script's own state file
[ -f "$STATE" ] && . "$STATE"
TNOW=$(date +%s)
ELAPSED=$(( TNOW - TPREV )); [ "$TPREV" -eq 0 ] && ELAPSED=0

[ -f "$OUT" ] || echo "timestamp,isp,probes_up,probes_total,loss_pct,rtt_min_ms,rtt_max_ms,jitter_ms,active_isp,rx_mbps,tx_mbps" > "$OUT"

# Throughput is logged as bytes actually moved per interval, not an active
# speed test. Every host available to run one from sits behind pve, whose NIC
# is the damaged 100Mbps port, so an active test would measure that port and
# nothing else. This is opportunistic -- it only shows what the link achieved
# while genuinely in use -- but it is free, uncapped, and identical for all
# three ISPs. The running maximum across busy intervals approximates what a
# link can actually deliver, which is the figure that collapsed today.
ifbytes() { tr "}" "\n" < "$IF" | grep "\"name\":\"$1\"" | grep -oE "\"$2\":\"[0-9]+\"" | grep -oE "[0-9]+" | head -1; }
R0=$(ifbytes wan-isp0 rx-byte);       T0=$(ifbytes wan-isp0 tx-byte)
R1=$(ifbytes wan-isp1 rx-byte);       T1=$(ifbytes wan-isp1 tx-byte)
R2=$(ifbytes wan-isp2 rx-byte);       T2=$(ifbytes wan-isp2 tx-byte)
for v in R0 T0 R1 T1 R2 T2; do eval "[ -n \"\$$v\" ] || $v=0"; done

awk -v ts="$(date -Is)" -v out="$OUT" -v state="$STATE.new" -v act="$ACTIVE" \
    -v p0d="$P0D" -v p0f="$P0F" -v p1d="$P1D" -v p1f="$P1F" -v p2d="$P2D" -v p2f="$P2F" \
    -v el="$ELAPSED" -v r0="$R0" -v t0="$T0" -v r1="$R1" -v t1="$T1" -v r2="$R2" -v t2="$T2" \
    -v b0r="$B0R" -v b0t="$B0T" -v b1r="$B1R" -v b1t="$B1T" -v b2r="$B2R" -v b2t="$B2T" '
  function ms(t,   s,m,u,v) {
    s = 0; m = 0; u = 0
    if (match(t, /[0-9]+s/))  { v = substr(t, RSTART, RLENGTH-1); s = v + 0 }
    if (match(t, /[0-9]+ms/)) { v = substr(t, RSTART, RLENGTH-2); m = v + 0 }
    if (match(t, /[0-9]+us/)) { v = substr(t, RSTART, RLENGTH-2); u = v + 0 }
    return s * 1000 + m + u / 1000
  }
  function field(obj, key,   re, v) {
    re = "\"" key "\":\"[^\"]*\""
    if (!match(obj, re)) return ""
    v = substr(obj, RSTART, RLENGTH)
    sub(/^"[^"]*":"/, "", v); sub(/"$/, "", v)
    return v
  }
  { data = data $0 }
  END {
    cur_r[0] = r0 + 0; cur_t[0] = t0 + 0; prev_r[0] = b0r + 0; prev_t[0] = b0t + 0
    cur_r[1] = r1 + 0; cur_t[1] = t1 + 0; prev_r[1] = b1r + 0; prev_t[1] = b1t + 0
    cur_r[2] = r2 + 0; cur_t[2] = t2 + 0; prev_r[2] = b2r + 0; prev_t[2] = b2t + 0
    prevd[0] = p0d + 0; prevf[0] = p0f + 0
    prevd[1] = p1d + 0; prevf[1] = p1f + 0
    prevd[2] = p2d + 0; prevf[2] = p2f + 0

    n = split(data, o, /\},\{/)
    for (i = 1; i <= n; i++) {
      c = field(o[i], "comment")
      k = -1
      if      (c ~ /ISP0/) k = 0
      else if (c ~ /ISP1/) k = 1
      else if (c ~ /ISP2/) k = 2
      else continue
      total[k]++
      done[k] += field(o[i], "done-tests") + 0
      fail[k] += field(o[i], "failed-tests") + 0
      if (field(o[i], "status") == "up") {
        up[k]++
        r = ms(field(o[i], "tcp-connect-time"))
        # Spread across probes is a cheap jitter proxy. The minimum alone
        # hides instability: 8ms +/-2 and 8ms +/-60 report identically.
        if (r > 0 && (best[k] == 0 || r < best[k])) best[k] = r
        if (r > worst[k]) worst[k] = r
      }
    }

    if (total[0] + total[1] + total[2] == 0) exit 1

    for (k = 0; k <= 2; k++) {
      if (total[k] == 0) continue
      dd = done[k] - prevd[k]; df = fail[k] - prevf[k]
      # Negative delta means the counters reset; fall back to cumulative
      # rather than emitting a nonsense negative loss figure.
      if (dd <= 0) { dd = done[k]; df = fail[k] }
      loss = (dd > 0) ? (df * 100.0 / dd) : 0
      rxd = cur_r[k] - prev_r[k]; txd = cur_t[k] - prev_t[k]
      if (el <= 0 || rxd < 0 || txd < 0) { rxm = 0; txm = 0 }
      else { rxm = rxd * 8 / el / 1000000; txm = txd * 8 / el / 1000000 }
      printf "%s,ISP%d,%d,%d,%.2f,%.1f,%.1f,%.1f,%s,%.2f,%.2f\n", ts, k, up[k] + 0, total[k], \
             loss, best[k] + 0, worst[k] + 0, (worst[k] + 0) - (best[k] + 0), act, rxm, txm >> out
      printf "P%dD=%d\nP%dF=%d\nB%dR=%d\nB%dT=%d\n", k, done[k] + 0, k, fail[k] + 0, \
             k, cur_r[k], k, cur_t[k] > state
    }
  }
' "$NW"

# Only advance the baseline if the sample was actually written, so a failed
# run does not silently swallow an interval of counters.
if [ -s "$STATE.new" ]; then echo "TPREV=$TNOW" >> "$STATE.new"; mv "$STATE.new" "$STATE"; fi
