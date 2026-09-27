# Queue trees, and why they are declared rather than hand-maintained.
#
# When ISP1 moved off PPPoE the migration updated the packet marks but not the
# tree they feed: ul-isp1 stayed parented to the deleted pppoe interface and
# ISP1 upload ran with no fq_codel for weeks. It does not show in a throughput
# test -- only as latency climbing under upload load -- and nothing noticed.
# Changing a link here means editing `parent`; everything dependent moves with
# it.

resource "routeros_queue_type" "fqc" {
  name = "fqc"
  kind = "fq-codel"
}

locals {
  # Shaping at 93-95% of the provisioned rate. The point is to own the queue:
  # if the bottleneck sits in the ISP's buffer instead of ours, fq_codel has
  # nothing to schedule and bufferbloat happens upstream where we cannot see it.
  #
  # These are HARD max-limits, so a figure set below the real line rate is lost
  # throughput, not a safety margin. ISP0 sat at 380M/186M from 2026-10-03 until
  # corrected -- the 400/200 plan had been written in a month before it took
  # effect, capping the work tier at 63% of a 600M line.
  #
  # PENDING 2026-11-02: Worldlink drops 600/300 -> 400/200. On that date set
  # isp0 to dl 380M / ul 186M, and change `caps` in scripts/isp-control.src from
  # "600,400,200" to "400,400,200" in the same commit -- caps feeds the ranking
  # score directly, so the two must not drift apart.
  wan = {
    isp0 = { dl_limit = "570M", ul_limit = "279M",
    dl_note = "95% of 600M PROVISIONED - drops to 400M on 2026-11-02", ul_note = "93% of 300M PROVISIONED - drops to 200M on 2026-11-02" }
    isp1 = { dl_limit = "380M", ul_limit = "186M",
    dl_note = "95% of 400M - verified 400 on-wire 2026-09-26", ul_note = "93% of 200M PROVISIONED" }
    isp2 = { dl_limit = "190M", ul_limit = "95M",
    dl_note = "95% of 200M PROVISIONED", ul_note = "95% of 100M PROVISIONED" }
  }
}

# Download shapes on the LAN side: the bottleneck for inbound traffic is the
# egress toward the clients, not the WAN interface it arrived on.
resource "routeros_queue_tree" "download" {
  for_each    = local.wan
  name        = "dl-${each.key}"
  parent      = local.bridge
  packet_mark = ["dl-${each.key}"]
  queue       = routeros_queue_type.fqc.name
  max_limit   = each.value.dl_limit
  comment     = "${upper(each.key)} download, ${each.value.dl_note}"
}

# Upload shapes on the WAN interface itself -- and this is the line that broke.
resource "routeros_queue_tree" "upload" {
  for_each    = local.wan
  name        = "ul-${each.key}"
  parent      = local.wan_iface[each.key]
  packet_mark = ["ul-${each.key}"]
  queue       = routeros_queue_type.fqc.name
  max_limit   = each.value.ul_limit
  comment     = "${upper(each.key)} upload, ${each.value.ul_note}"
}
