# Health probes. Netwatch ONLY MEASURES -- all decisions live in the scheduler
# script (script.tf).
#
# TRAP: a script invoked from a netwatch up/down hook cannot persist a :global.
# The assignment succeeds, reads back fine within the same run, and is gone by
# the next. Any scoring state silently resets on every probe while looking like
# it works. These entries carry no up_script or down_script; adding one brings
# the trap back.
#
# Each probe is pinned to its ISP by the matching rule in routing.tf, driven
# from the same map so the two cannot drift. That pairing is load-bearing: an
# unpinned probe follows the main table, measures whichever link is primary,
# and reports it under the wrong ISP's name -- reading healthy at exactly the
# moment its own link dies.

# Measured limits (RouterOS 7, not documented anywhere obvious):
#   interval  minimum 1s. "500ms" is rejected. Fractional values ABOVE 1s are
#             accepted and normalised: "1100ms" -> "1s100ms".
#   timeout   accepts sub-second freely.
#
# Hence 1 / 1.1 / 1.2. The slowest probe on a link sets the hard-down floor so
# all three must sit near 1s, but three probes at exactly 1s share a phase and
# a momentary router stall drops them together, manufacturing a false
# hard-down. 0.2s of spread avoids that.
#
# Slot assignment is by intent, not sort order: the loss score pools done/failed
# across a link's probes, so rate is weight. At 1 / 1.1 / 1.2 the shares are
# 36.5 / 33.1 / 30.4, and putting the domestic probe last keeps ~70% of each
# link's loss signal on transit-crossing targets.
locals {
  # Fast slot: large operators that also cross international transit.
  probe_fast = ["8.8.8.8", "8.8.4.4", "208.67.220.220"]

  # Slow slot: domestic, kept as the diagnostic separating "link dead" from
  # "transit dead". Slowest on purpose -- least weight.
  probe_domestic = ["1.1.1.2", "1.0.0.2", "1.1.1.3"]

  probe_interval = {
    for addr, isp in local.probe_pins :
    addr => contains(local.probe_fast, addr) ? "1s" : (
      contains(local.probe_domestic, addr) ? "1200ms" : "1100ms"
    )
  }

  # Latency thresholds. A breach sets status=down, so a slow link takes the same
  # reputation hit as a dead one -- which closes the blind spot loss counting
  # leaves: a link degrading from 20ms to 800ms completes every connect, so
  # failed-tests stays 0 and reputation stays perfect while the link is useless
  # for a call.
  #
  # Three tiers rather than one value because the targets differ by 60x
  # (Cloudflare 1.6ms, OpenDNS 98ms over the same router). All sit below the
  # 500ms timeout so the threshold trips first and the reason is recorded as
  # degradation rather than a dead probe. Indexed directly, not looked up with a
  # default, so adding a target without choosing a threshold fails the plan.
  probe_thr = merge(
    { for a in local.probe_domestic : a => "100ms" },                                         # 1.6-10ms measured
    { for a in ["8.8.8.8", "8.8.4.4"] : a => "300ms" },                                       # 18-60ms
    { for a in ["76.76.2.0", "45.90.28.0", "208.67.220.220", "194.242.2.2"] : a => "400ms" }, # 37-98ms
  )
}

# Why TCP/443 and not ICMP: carriers deprioritise or police ping, so ICMP loss
# does not imply traffic loss. A completed handshake on the port everything uses
# is the closest cheap proxy for "this link works".
#
# Why three targets on three different operators: one operator having a bad day
# must not read as an ISP outage. The controller needs agreement across all
# three before scoring a link down.
#
# Why none of these is ever a configured resolver: the pins use
# lookup-only-in-table, which has no fallthrough, so pinning 1.1.1.1 to one ISP
# would take DNS down with that ISP. addressing.tf resolves via 1.1.1.1/1.0.0.1;
# the Cloudflare targets here are the alternates 1.1.1.2 / 1.0.0.2 / 1.1.1.3,
# which nothing resolves through.
resource "routeros_tool_netwatch" "probe" {
  for_each = local.probe_pins

  name = "${upper(each.value)}-${each.key}"
  host = each.key
  type = "tcp-conn"
  port = 443

  interval = local.probe_interval[each.key]

  # Measured connect times: 1.6ms fastest, 98.3ms slowest, p95 within 10% of
  # median on all nine. So 5x headroom on the worst target.
  #
  # The risk of lowering it further is not a false failover -- that needs all
  # three probes -- it is reputation, since the three are pooled and one
  # spurious timeout reads as ~33% loss for that tick. If failures appear across
  # all nine at once, raise this first.
  timeout = "500ms"

  thr_tcp_conn_time = local.probe_thr[each.key]

  # Pinned empty permanently. This is what ENFORCES the rule at the top of this
  # file: a down-script here silently breaks the controller's state rather than
  # failing loudly. Also not free to remove -- down_script is Optional and not
  # Computed (the CPE entries below sit at null while these sit at ""), so
  # deleting this line plans "" -> null on all nine probes.
  down_script = ""

  comment = "${upper(each.value)}-probe"

  depends_on = [routeros_routing_rule.probe_pin]
}

# Is the CPE itself still on the wire? Distinguishes "our CPE vanished" from
# "the carrier's network is down" -- the ISP1 route going INACTIVE means
# 192.168.2.1 stopped answering, which is a fault on our side of the demarc.
# This is the evidence to put in front of a provider.
#
# ICMP rather than TCP/443 despite the argument above: these are
# directly-connected neighbours, where ICMP is the honest test, and the CPEs
# serve nothing useful on TCP.
#
# Deliberately NOT named "*-probe". ISP-control selects comment="ISPn-probe" and
# ISP-probe-why selects comment~"-probe$" -- a CPE dropping out must not move a
# route, nor consume the retest budget belonging to the real probes.
resource "routeros_tool_netwatch" "cpe" {
  for_each = local.gw

  # local.gw is address%interface for route disambiguation; netwatch wants the
  # bare address.
  name     = "${upper(each.key)}-cpe"
  host     = split("%", each.value)[0]
  type     = "icmp"
  interval = "10s"
  timeout  = "1s"
  comment  = "${upper(each.key)}-cpe reachability (diagnostic only)"
}
