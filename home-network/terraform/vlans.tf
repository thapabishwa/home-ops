# VLANs on the trunk.
#
# Everything WAN rides tags on ether1, the single 30m cable to the SG108E. A
# second cable was ruled out on distance, so all three ISPs plus the remote LAN
# share that one link -- which is why the VLAN scheme exists at all.
#
# The bridge itself, the ether2-ether5 ports and 10.0.0.1/24 are NOT here. See
# "The bootstrap" in README.md: Terraform reaches the router through them, and
# a tool cannot manage the path it depends on to reach anything.

locals {
  bridge = "bridge-lan"

  vlans = {
    lan-remote = { id = 90, comment = "LAN extension to SG108E ports 5-7" }
    wan-isp0   = { id = 10, comment = "ISP0 Worldlink" }
    wan-isp1   = { id = 20, comment = "ISP1 Vianet" }
    wan-isp2   = { id = 30, comment = "ISP2 NTFiber" }
  }

  # Referenced as resource attributes elsewhere, not as bare strings: RouterOS
  # rejects a write naming an interface that does not exist yet, and a literal
  # would tell Terraform nothing about ordering. That cost two of six mangle
  # rules on an earlier run.
  wan_iface = {
    for k, v in routeros_interface_vlan.this : replace(k, "wan-", "") => v.name
    if startswith(k, "wan-")
  }
}

resource "routeros_interface_vlan" "this" {
  for_each  = local.vlans
  name      = each.key
  vlan_id   = each.value.id
  interface = "ether1"
  comment   = each.value.comment
}

# The remote LAN joins the bridge. Safe to manage here, unlike the wired ports:
# nothing reaches this router over VLAN 90 to configure it.
resource "routeros_interface_bridge_port" "lan_remote" {
  bridge    = local.bridge
  interface = routeros_interface_vlan.this["lan-remote"].name
  comment   = "remote LAN via switch VLAN 90"
}
