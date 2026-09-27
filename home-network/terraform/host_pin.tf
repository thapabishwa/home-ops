# Per-host ISP pin -- force one device onto one ISP, overriding its tier.
# Delete the entry to return the host to its tier.
#
# Mangle marks, not a routing rule: new routing rules append below
# `src 10.0.0.0/24` and are dead config, and there is no place_before for them.
# A routing mark beats the rules from any position (see downloads.tf).
#
# Two steps, as in downloads.tf: fasttrack skips marked CONNECTIONS, so marking
# the connection first is what keeps the routing mark alive past packet one.
# LAN destinations excluded or the host loses DNS and every local service.
#
# Only new connections are pinned, and pinned hosts lose fasttrack -- fine for
# a handful, not a subnet.
locals {
  # Bare address, not /32 -- RouterOS strips it and every plan would show drift.
  host_pins = {
    # MBP-14 on ISP1. Both addresses are the same machine -- real MAC and
    # USB-Ethernet -- so pinning it needs both.
    # "10.0.0.17" = "isp1"
    # "10.0.0.19" = "isp1"
  }
}

resource "routeros_ip_firewall_mangle" "host_pin_conn" {
  for_each = local.host_pins

  chain               = "prerouting"
  action              = "mark-connection"
  src_address         = each.key
  dst_address         = "!${local.lan_subnet}"
  connection_state    = "new"
  new_connection_mark = "pin-${each.value}"
  passthrough         = true # must continue to the mark-routing rule
  comment             = "host pin ${each.key} -> ${upper(each.value)}"
}

resource "routeros_ip_firewall_mangle" "host_pin_route" {
  for_each = local.host_pins

  chain            = "prerouting"
  action           = "mark-routing"
  src_address      = each.key
  dst_address      = "!${local.lan_subnet}"
  connection_mark  = "pin-${each.value}"
  new_routing_mark = "via-${each.value}"
  passthrough      = false
  comment          = "host pin ${each.key} ${upper(each.value)} -> routing mark"

  depends_on = [routeros_ip_firewall_mangle.host_pin_conn]
}
