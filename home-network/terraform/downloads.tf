# Bulk transfer, split across ISP1 and ISP2.
#
# qBittorrent is the one workload where aggregating links pays: it opens
# hundreds of independent peer connections, so per-connection balancing
# multiplies throughput. A single TCP flow never can.

locals {
  # qBittorrent's LAN address: a macvlan interface on its pod in the cluster
  # (kubernetes/apps/media/qbittorrent.yaml).
  #
  # A bare address, not /32. RouterOS stores a single-host src-address without
  # the prefix, so writing /32 makes every plan report six mangle rules as
  # changed and every apply "fix" them back, forever.
  download_host = "10.0.0.11"

  # ISP0 deliberately excluded. At any instant one peer is sending and one flow
  # leaves by one link, so the ceiling is the sending peer, not the link -- adding
  # ISP0 bought no speed while making bulk transfer the largest thing on the
  # work link, which the tier design exists to keep clear.
  #
  # Not absolute: via-isp1 and via-isp2 both carry ISP0 as a fallback, so the
  # download lands on it rather than blackholing if both of these fail.
  isp_index = { isp1 = 0, isp2 = 1 }

  # EXCLUDED FROM MARKING -- a bug fix, not an optimisation.
  #
  # A routing mark BEATS the routing rules: `dst 10.0.0.0/24 -> main` loses to
  # it. The via-ispN tables hold nothing but default routes -- no connected
  # route for the LAN, no local route for the router -- so a marked packet from
  # the download host to 10.0.0.1 matched 0.0.0.0/0 and left via a WAN
  # interface, never reaching the router's input chain.
  #
  # Internet traffic was fine, since a default route is the right answer for it.
  # Everything LOCAL broke, including DNS -- so the client had a valid listen
  # socket and no way to resolve a name. It looked like a dead download.
  #
  # Only the LAN is excluded, not the CPE subnets: dst-address takes a single
  # value, and the download host talking to a CPE is not a real case.
  lan_subnet = "10.0.0.0/24"
}

# Step 1: classify new connections into buckets.
#
# `both-addresses-and-ports` hashes source and destination together so a peer
# conversation always lands on the same link. A connection that changed egress
# mid-stream would change public IP and be dropped by the far end.
resource "routeros_ip_firewall_mangle" "downloads_pcc" {
  for_each = local.isp_index

  chain            = "prerouting"
  action           = "mark-connection"
  src_address      = local.download_host
  dst_address      = "!${local.lan_subnet}"
  connection_state = "new"

  # Denominator from the map, not hardcoded: a 3-way hash feeding 2 buckets
  # drops a third of connections into a mark nothing routes.
  per_connection_classifier = "both-addresses-and-ports:${length(local.isp_index)}/${each.value}"
  new_connection_mark       = "dl-${each.key}"
  passthrough               = true # must continue to the mark-routing rules
  comment                   = "download split ${each.value}/${length(local.isp_index)} -> ${upper(each.key)}"

  depends_on = [routeros_interface_vlan.this]
}

# Step 2: connection mark -> routing mark, on every packet rather than just the
# first.
#
# The routing mark must name an EXISTING table; RouterOS rejects an invented one
# with "input does not match any value of new-routing-mark". Hence via-ispN, the
# tier table itself. The connection mark above stays free-form, which is why
# those rules applied when these did not.
resource "routeros_ip_firewall_mangle" "downloads_route" {
  for_each = local.isp_index

  chain           = "prerouting"
  action          = "mark-routing"
  src_address     = local.download_host
  dst_address     = "!${local.lan_subnet}"
  connection_mark = "dl-${each.key}"

  new_routing_mark = "via-${each.key}"
  passthrough      = false
  comment          = "download ${upper(each.key)} -> routing mark"

  depends_on = [routeros_ip_firewall_mangle.downloads_pcc]
}

# Step 3: send each mark at its tier table. Reusing via-ispN rather than
# dedicated tables means a bucket whose link dies follows the same fallback as
# everything else.
#
# Position does NOT matter -- these sit below the `src 10.0.0.0/24` tier rule
# and the marks are honoured anyway, since routing marks beat routing rules.
# They may be redundant; nothing has tested removing them.
resource "routeros_routing_rule" "downloads" {
  for_each = local.isp_index

  action       = "lookup"
  routing_mark = "via-${each.key}"
  table        = "via-${each.key}"
  comment      = "TIER bulk: downloads via ${upper(each.key)}"

  depends_on = [routeros_routing_table.this]
}

# Renamed from torrent_*; the same rules on the router, updated in place.
moved {
  from = routeros_ip_firewall_mangle.torrent_pcc
  to   = routeros_ip_firewall_mangle.downloads_pcc
}

moved {
  from = routeros_ip_firewall_mangle.torrent_route
  to   = routeros_ip_firewall_mangle.downloads_route
}

moved {
  from = routeros_routing_rule.torrent
  to   = routeros_routing_rule.downloads
}
