#!/bin/sh
# Dual-WAN health as JSON for Homepage, read from the MikroTik hEX.
#
# Replaces the OPNsense version, which scraped opnsense_gateway_* out of
# node_exporter on 10.0.0.1:9100. That address is the hEX now and it runs no
# node_exporter, so the old script silently published up:0 / loss:100 for
# both gateways -- a dashboard confidently reporting a total outage.
#
# RouterOS has a REST API, so there is nothing to scrape: /rest/tool/netwatch
# returns the six health probes (three per ISP, three independent operators
# each) and carries tcp-connect-time, which is a real latency figure for a
# completed TCP handshake -- a better signal than the old ICMP gateway RTT,
# because it proves the ISP's upstream works rather than that its CPE is awake.
#
# Reported per ISP: probes up out of total, and the LOWEST connect time among
# the probes that are up. Lowest, not mean: a slow third-party responder
# should not read as a slow link, and the floor across three operators is the
# closest thing to the path's own latency.
#
# `uptime` comes straight from /rest/system/resource. `active` -- which
# default route in the main table is actually carrying traffic -- is still
# emitted even though the widget no longer shows it: it is the one field that
# distinguishes "both ISPs reachable" from "something is actually routing",
# and reads "none" if no default route is active at all.

. ${CONF_DIR:-/etc}/hex-api.conf

OUT=${WWW_DIR:-/var/www/wan}/wan.json
# Loss is only meaningful as a delta. done-tests/failed-tests are cumulative
# since the probe started, so a link that was down for hours still reads near
# 100 percent lost long after it recovers. Previous totals are kept here and
# differenced each run, giving loss over the polling interval instead.
STATE=${STATE_DIR:-/var/lib}/hex-probe-state
NW=$(mktemp)
RT=$(mktemp)
SY=$(mktemp)
trap 'rm -f "$NW" "$RT" "$SY" "$OUT.tmp"' EXIT

[ -n "$HEX_HOST" ] && [ -n "$HEX_USER" ] && [ -n "$HEX_PASS" ] || {
    logger -t wan-json "credentials not set"; exit 1; }

P0D=0; P0F=0; P1D=0; P1F=0; P2D=0; P2F=0
# shellcheck source=/dev/null  # this script's own state file
[ -f "$STATE" ] && . "$STATE"

curl -s -m 8 -u "$HEX_USER:$HEX_PASS" \
     "http://$HEX_HOST/rest/tool/netwatch" > "$NW" 2>/dev/null
curl -s -m 8 -u "$HEX_USER:$HEX_PASS" \
     "http://$HEX_HOST/rest/ip/route?dst-address=0.0.0.0/0" > "$RT" 2>/dev/null
curl -s -m 8 -u "$HEX_USER:$HEX_PASS" \
     "http://$HEX_HOST/rest/system/resource" > "$SY" 2>/dev/null

{ echo "===NETWATCH==="; cat "$NW"; echo
  echo "===ROUTES===";   cat "$RT"; echo
  echo "===SYSTEM===";   cat "$SY"; } | awk -v p0d="$P0D" -v p0f="$P0F" -v p1d="$P1D" -v p1f="$P1F" \
            -v p2d="$P2D" -v p2f="$P2F" -v state="$STATE.new" '
  # RouterOS durations arrive as 4ms441us / 270ms425us / 1s50ms.
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
  /^===NETWATCH===/ { sec = "nw"; next }
  /^===ROUTES===/   { sec = "rt"; next }
  /^===SYSTEM===/   { sec = "sy"; next }
  sec == "nw" { nw = nw $0 }
  sec == "rt" { rt = rt $0 }
  sec == "sy" { sy = sy $0 }
  END {
    n = split(nw, o, /\},\{/)
    for (i = 1; i <= n; i++) {
      c = field(o[i], "comment")
      if      (c ~ /ISP0/) isp = "ISP0"
      else if (c ~ /ISP1/) isp = "ISP1"
      else if (c ~ /ISP2/) isp = "ISP2"
      else continue
      total[isp]++
      done[isp] += field(o[i], "done-tests") + 0
      fail[isp] += field(o[i], "failed-tests") + 0
      if (field(o[i], "status") == "up") {
        up[isp]++
        r = ms(field(o[i], "tcp-connect-time"))
        if (r > 0 && (best[isp] == 0 || r < best[isp])) best[isp] = r
      }
    }

    # RouterOS omits "active" entirely when false, so presence is the test.
    active = "none"
    n = split(rt, o, /\},\{/)
    for (i = 1; i <= n; i++) {
      if (field(o[i], "routing-table") != "main") continue
      if (field(o[i], "active") != "true") continue
      c = field(o[i], "comment")
      if      (c ~ /ISP0/) active = "ISP0"
      else if (c ~ /ISP1/) active = "ISP1"
      else if (c ~ /ISP2/) active = "ISP2"
    }

    # No probes parsed means the fetch or the API failed. Emitting zeroes here
    # is what made the old script lie, so publish nothing and let the previous
    # file stand.
    if (total["ISP0"] + total["ISP1"] + total["ISP2"] == 0) exit 1

    prevd["ISP0"] = p0d + 0; prevf["ISP0"] = p0f + 0
    prevd["ISP1"] = p1d + 0; prevf["ISP1"] = p1f + 0
    prevd["ISP2"] = p2d + 0; prevf["ISP2"] = p2f + 0

    printf "{"
    for (k = 0; k <= 2; k++) {
      isp = "ISP" k
      # Counters reset on reboot, so a negative delta means the probe
      # restarted -- fall back to cumulative rather than reporting nonsense.
      dd = done[isp] - prevd[isp]; df = fail[isp] - prevf[isp]
      if (dd <= 0) { dd = done[isp]; df = fail[isp] }
      loss = (dd > 0) ? (df * 100.0 / dd) : 0
      printf "\"%s\":{\"up\":%d,\"of\":%d,\"probes\":\"%d/%d\",\"rtt_ms\":%.1f,\"loss_pct\":%.1f},", \
             isp, up[isp] + 0, total[isp] + 0, up[isp] + 0, total[isp] + 0, best[isp] + 0, loss
      printf "P%dD=%d\nP%dF=%d\n", k, done[isp] + 0, k, fail[isp] + 0 > state
    }
    uptime = field(sy, "uptime")
    if (uptime == "") uptime = "?"
    printf "\"uptime\":\"%s\",\"active\":\"%s\"}\n", uptime, active
  }
' > "$OUT.tmp" 2>/dev/null

# Publish only a complete parse -- stale data beats wrong data on a dashboard.
if [ -s "$OUT.tmp" ] && grep -q '"active"' "$OUT.tmp"; then
    mv "$OUT.tmp" "$OUT"
    [ -s "$STATE.new" ] && mv "$STATE.new" "$STATE"
else
    logger -t wan-json "parse failed - REST unreachable, credentials rejected, or schema changed"
fi
