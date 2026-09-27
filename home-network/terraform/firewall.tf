# Firewall, NAT and packet marking.
#
# Rule ORDER is load-bearing: RouterOS evaluates each chain top-down and the
# first match wins. Terraform creates resources in parallel unless something
# forces a sequence, so the filter rules below are chained with depends_on to
# pin their creation order. That is the only reason they are written out one by
# one instead of as a for_each -- a list would apply in arbitrary order and
# could land "drop everything else from WAN" above "accept all from LAN".
#
# NAT and mangle need no such chain: every rule matches a distinct interface,
# so no two can both match the same packet.

# fasttrack sits first on purpose: it short-circuits established flows past the
# rest of the forward chain AND past mangle entirely, for roughly 3x less CPU.
#
# connection_mark = no-mark is what makes downloads.tf possible. Without it a
# PCC-balanced connection takes its routing mark on the first packet and loses
# it on every one after. Excluding marked connections keeps the CPU saving for
# the other 99% of traffic while letting the split work for the one host that
# needs it.
resource "routeros_ip_firewall_filter" "fasttrack" {
  chain            = "forward"
  action           = "fasttrack-connection"
  connection_state = "established,related"
  connection_mark  = "no-mark"
  comment          = "fasttrack - all established, except marked"
}

resource "routeros_ip_firewall_filter" "input_established" {
  chain            = "input"
  action           = "accept"
  connection_state = "established,related,untracked"
  comment          = "accept established/related"
  depends_on       = [routeros_ip_firewall_filter.fasttrack]
}

resource "routeros_ip_firewall_filter" "input_invalid" {
  chain            = "input"
  action           = "drop"
  connection_state = "invalid"
  comment          = "drop invalid"
  depends_on       = [routeros_ip_firewall_filter.input_established]
}

resource "routeros_ip_firewall_filter" "input_icmp" {
  chain      = "input"
  action     = "accept"
  protocol   = "icmp"
  comment    = "accept ICMP"
  depends_on = [routeros_ip_firewall_filter.input_invalid]
}

resource "routeros_ip_firewall_filter" "input_lan" {
  chain             = "input"
  action            = "accept"
  in_interface_list = "LAN"
  comment           = "accept all from LAN"
  depends_on        = [routeros_ip_firewall_filter.input_icmp]
}

# ether1 is in the WAN list, so this drop also covers the SG108E management
# link. Reaching the switch UI goes through Caddy on the LAN side, not here.
resource "routeros_ip_firewall_filter" "input_drop_wan" {
  chain             = "input"
  action            = "drop"
  in_interface_list = "WAN"
  comment           = "drop everything else from WAN"
  depends_on        = [routeros_ip_firewall_filter.input_lan]
}

resource "routeros_ip_firewall_filter" "fwd_established" {
  chain            = "forward"
  action           = "accept"
  connection_state = "established,related,untracked"
  comment          = "accept established/related"
  depends_on       = [routeros_ip_firewall_filter.input_drop_wan]
}

resource "routeros_ip_firewall_filter" "fwd_invalid" {
  chain            = "forward"
  action           = "drop"
  connection_state = "invalid"
  comment          = "drop invalid"
  depends_on       = [routeros_ip_firewall_filter.fwd_established]
}

resource "routeros_ip_firewall_filter" "fwd_lan_wan" {
  chain              = "forward"
  action             = "accept"
  in_interface_list  = "LAN"
  out_interface_list = "WAN"
  comment            = "LAN to WAN"
  depends_on         = [routeros_ip_firewall_filter.fwd_invalid]
}

resource "routeros_ip_firewall_filter" "fwd_drop_new_wan" {
  chain             = "forward"
  action            = "drop"
  connection_state  = "new"
  in_interface_list = "WAN"
  comment           = "drop new from WAN"
  depends_on        = [routeros_ip_firewall_filter.fwd_lan_wan]
}

# One masquerade per WAN, and the set must stay COMPLETE. Router-originated
# traffic sources from the WAN address and needs no NAT, so a missing rule
# leaves the router -- and therefore every netwatch probe and the controller's
# view of the link -- working normally while LAN hosts behind it cannot reach
# anything through that ISP.
resource "routeros_ip_firewall_nat" "masquerade" {
  for_each = local.wan_iface
  chain    = "srcnat"
  action   = "masquerade"

  # From 01-l2's output rather than a literal. RouterOS validates the
  # interface name on write and rejects one that does not exist yet ("input
  # does not match any value of interface"); the stack dependency is what
  # guarantees the VLANs are already there.
  out_interface = each.value
  comment       = each.key == "isp2" ? "ISP2 NTFiber" : null
}

# Packet marks feed the queue trees in queues.tf. A mark whose interface has
# gone away is not an error -- the traffic is simply never matched and runs
# unshaped, silently. Declaring marks and trees together is what stops them
# drifting apart; see queues.tf.
locals {
  isps = ["isp0", "isp1", "isp2"]
}

resource "routeros_ip_firewall_mangle" "download" {
  for_each        = toset(local.isps)
  chain           = "forward"
  action          = "mark-packet"
  in_interface    = local.wan_iface[each.key]
  new_packet_mark = "dl-${each.key}"
  passthrough     = false
  comment         = "download via ${upper(each.key)}"
}

resource "routeros_ip_firewall_mangle" "upload" {
  for_each        = toset(local.isps)
  chain           = "forward"
  action          = "mark-packet"
  out_interface   = local.wan_iface[each.key]
  new_packet_mark = "ul-${each.key}"
  passthrough     = false
  comment         = "upload via ${upper(each.key)}"
}
