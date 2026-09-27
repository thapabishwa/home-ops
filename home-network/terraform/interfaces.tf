# Interface lists. These are policy rather than layer 2 -- they exist so the
# firewall can say "from WAN" instead of naming three VLANs -- so they live
# here and not in 01-l2.

resource "routeros_interface_list" "this" {
  for_each = toset(["WAN", "LAN"])
  name     = each.key
}

# ether1 is deliberately in WAN, not LAN. It is the trunk carrying every ISP
# VLAN, and the SG108E's management CPU answers on it -- so it is treated as
# untrusted and the input drop rules apply to it.
locals {
  list_members = merge(
    { for k, v in local.wan_iface : v => { list = "WAN", comment = k == "isp2" ? "ISP2 NTFiber" : null } },
    {
      (local.bridge)                                    = { list = "LAN", comment = null }
      (routeros_interface_vlan.this["lan-remote"].name) = { list = "LAN", comment = "remote LAN at switch - same policy as bridge-lan" }
      ether1                                            = { list = "WAN", comment = "SG108E mgmt link - untrusted, treat as WAN" }
    },
  )
}

resource "routeros_interface_list_member" "this" {
  for_each  = local.list_members
  interface = each.key
  list      = each.value.list
  comment   = each.value.comment

  depends_on = [routeros_interface_list.this]
}
