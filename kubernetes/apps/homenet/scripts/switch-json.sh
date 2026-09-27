#!/bin/sh
# TL-SG108E port statistics as JSON for Homepage.
#
# The switch has no SNMP and no API -- only a web UI whose pages carry their
# data as inline JavaScript. So this logs in, fetches one page, and parses
# the arrays out of it.
#
# It permits ONE web session at a time: every run here logs you out of the
# UI, and logging into the UI breaks the next run. Cron is authoritative for
# the interval (*/5); SWITCH_POLL in the config records the intent.

. ${CONF_DIR:-/etc}/switch-scrape.conf

OUT=${WWW_DIR:-/var/www/wan}/switch.json
CJ=$(mktemp)
PAGE=$(mktemp)
trap 'rm -f "$CJ" "$PAGE" "$OUT.tmp"' EXIT

[ -n "$SWITCH_USER" ] && [ -n "$SWITCH_PASS" ] || { logger -t switch-json "credentials not set"; exit 1; }

curl -s -o /dev/null -m 15 -c "$CJ" \
  -H "Referer: http://$SWITCH_HOST/" \
  --data-urlencode "username=$SWITCH_USER" \
  --data-urlencode "password=$SWITCH_PASS" \
  --data "cpassword=&logon=Login" \
  "http://$SWITCH_HOST/logon.cgi" 2>/dev/null

curl -s -o "$PAGE" -m 15 -b "$CJ" \
  -H "Referer: http://$SWITCH_HOST/" \
  "http://$SWITCH_HOST/PortStatisticsRpm.htm" 2>/dev/null

awk '
  /max_port_num/ && !mp { t=$0; gsub(/[^0-9]/,"",t); mp=t+0 }
  /link_status:\[/      { t=$0; sub(/.*link_status:\[/,"",t); sub(/\].*/,"",t); ls=t }
  /pkts:\[/             { t=$0; sub(/.*pkts:\[/,"",t);        sub(/\].*/,"",t); pk=t }
  END {
    if (mp == 0 || ls == "" || pk == "") exit 1
    split(ls, L, ","); split(pk, P, ",")
    TRUNK = 8                       # port facing the hEX; see err_total below
    # link_status, verified against the switch own Port Status page on this
    # unit (V6, firmware 20211209): 6 is 1000Full, 5 is 100Full, 0 is down.
    # The previous mapping treated 5 and 6 alike as gigabit, so a trunk
    # sitting at 100Full reported as 1G and sub_gig stayed 0 -- hiding the
    # exact condition this counter exists to surface. 6 is the top value on
    # a gigabit switch, so anything else still linked is below gigabit.
    gig = 0; sub_gig = 0; down = 0; err = 0; sep = ""
    printf "{\"ports\":["
    for (i = 1; i <= mp; i++) {
      c = L[i] + 0
      name = (c == 0) ? "down" : (c == 6) ? "1G" : (c == 5) ? "100M" : "sub-1G"
      # A linked port below gigabit is the interesting case: it means the
      # link negotiated down, which usually points at the cable or the port,
      # not the far end deliberately running slow.
      if (c == 0)      down++
      else if (c == 6) gig++
      else             sub_gig++
      b = (i - 1) * 4
      txg = P[b+1]+0; txb = P[b+2]+0; rxg = P[b+3]+0; rxb = P[b+4]+0
      # The trunk rx_err is deliberately left out of err_total. Port 8 is
      # the only port that receives tagged frames, and this chipset counts
      # minimum-size tagged frames under RxGoodPkt and RxBadPkt both, so the
      # counter is permanently non-zero and rises and falls with the share of
      # small upstream frames -- measured at 7.4% of ingress while download
      # heavy and 2.0% while uploading, with zero packet loss, zero FCS or
      # fragment errors on the far end, and every good frame reconciling to
      # within 0.2% throughout. Including it meant err_total could never read
      # zero, which made the one field that should mean "something is wrong"
      # mean nothing at all. tx_err is still counted on every port including
      # this one, and the raw figure is still published as trunk_rx_err.
      err += txb + (i == TRUNK ? 0 : rxb)
      printf "%s{\"n\":%d,\"link\":\"%s\",\"tx\":%d,\"rx\":%d,\"tx_err\":%d,\"rx_err\":%d}", \
             sep, i, name, txg, rxg, txb, rxb
      sep = ","
      link[i] = name; rxerr[i] = rxb
    }
    printf "],"
    printf "\"gig\":%d,\"sub_gig\":%d,\"down\":%d,", gig, sub_gig, down
    printf "\"ports_up\":%d,\"err_total\":%d,", gig + sub_gig, err
    printf "\"isp0_link\":\"%s\",\"isp1_link\":\"%s\",", link[1], link[2]
    printf "\"trunk_link\":\"%s\",\"trunk_rx_err\":%d", link[8], rxerr[8]
    printf "}\n"
  }
' "$PAGE" > "$OUT.tmp" 2>/dev/null

# Publish only a complete parse -- a failed login returns the login page,
# which parses to nothing, and stale data beats wrong data on a dashboard.
if [ -s "$OUT.tmp" ] && grep -q '"ports_up"' "$OUT.tmp"; then
    mv "$OUT.tmp" "$OUT"
else
    logger -t switch-json "parse failed - login rejected or page layout changed"
fi
