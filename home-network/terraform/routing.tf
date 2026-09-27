# Policy routing: tables, default routes and the rules that steer into them.
#
# OWNERSHIP SPLIT -- the most important thing in this repo:
#   Terraform    which routes EXIST (gateway, table, comment)
#   ISP-control  nothing but `distance`, rewritten every 10s from reputation
#
# Hence ignore_changes = [distance] on every route. Without it a plan shows
# three tables of drift every run and an apply fights the controller; with it,
# any diff means a route was added, removed or repointed.

locals {
  # A gateway is written as address%interface. The interface qualifier is not
  # decoration: all three CPEs hand out RFC1918 gateways and 192.168.x.1 is
  # ambiguous across them, so the route has to say which link it means.
  gw = {
    isp0 = "192.168.1.254%wan-isp0"
    isp1 = "192.168.2.1%wan-isp1"
    isp2 = "192.168.100.1%wan-isp2"
  }
}

resource "routeros_routing_table" "this" {
  for_each = {
    via-isp0   = "policy: force ISP0"
    via-isp1   = "policy: force ISP1"
    via-isp2   = "policy: force ISP2"
    probe-isp0 = "ISP0 health probe path"
    probe-isp1 = "ISP1 health probe path"
    probe-isp2 = "ISP2 health probe path"
  }
  name    = each.key
  comment = each.value
  fib     = true
}

# Every table carries all three ISPs. That completeness IS the failover: a tier
# whose link dies falls through to the next distance in its OWN table. Written
# with one route each originally, and a device class went dark the first time
# its link failed.
#
# Distances here are the intended resting state, not live values -- the
# controller overwrites them within 10s, adding +50 to any hard-down link.
locals {
  routes = merge(
    # main: follows the damped primary. Devices with no matching tier rule and
    # the router's own traffic use this table.
    {
      for isp, gw in local.gw : "main-${isp}" => {
        table    = "main"
        gateway  = gw
        distance = index(["isp0", "isp1", "isp2"], isp) + 1
        comment  = "${upper(isp)} ${ { isp0 = "Worldlink", isp1 = "Vianet", isp2 = "NTFiber" }[isp]} (CGNAT) - rank managed by ISP-control"
      }
    },
    # via-isp0 -- work tier: pve, the wired Macs and the real-MAC block.
    {
      "via-isp0-isp0" = { table = "via-isp0", gateway = local.gw.isp0, distance = 1, comment = "ISP0 policy route" }
      "via-isp0-isp1" = { table = "via-isp0", gateway = local.gw.isp1, distance = 2, comment = "via-isp0 fallback, egress wan-isp1" }
      "via-isp0-isp2" = { table = "via-isp0", gateway = local.gw.isp2, distance = 3, comment = "via-isp0 tier: ISP2 fallback" }
    },
    # via-isp1 -- household tier: everything in the /24 not matched earlier.
    {
      "via-isp1-isp1" = { table = "via-isp1", gateway = local.gw.isp1, distance = 1, comment = "ISP1 policy route" }
      "via-isp1-isp0" = { table = "via-isp1", gateway = local.gw.isp0, distance = 2, comment = "via-isp1 fallback, egress wan-isp0" }
      "via-isp1-isp2" = { table = "via-isp1", gateway = local.gw.isp2, distance = 3, comment = "via-isp1 tier: ISP2 fallback" }
    },
    # via-isp2 -- guest tier: the unreserved DHCP pool.
    {
      "via-isp2-isp2" = { table = "via-isp2", gateway = local.gw.isp2, distance = 1, comment = "ISP2 policy route" }
      "via-isp2-isp0" = { table = "via-isp2", gateway = local.gw.isp0, distance = 2, comment = "via-isp2 tier: ISP0 fallback" }
      "via-isp2-isp1" = { table = "via-isp2", gateway = local.gw.isp1, distance = 3, comment = "via-isp2 tier: ISP1 fallback" }
    },
  )
}

resource "routeros_ip_route" "wan" {
  for_each = local.routes

  dst_address   = "0.0.0.0/0"
  gateway       = each.value.gateway
  routing_table = each.value.table
  distance      = each.value.distance
  comment       = each.value.comment
  check_gateway = "ping"
  disabled      = false

  lifecycle {
    ignore_changes = [distance]
  }

  depends_on = [routeros_routing_table.this, routeros_ip_address.wan_isp1,
  routeros_ip_dhcp_client.wan]
}

# Probe paths behave differently on purpose.
#
# No check_gateway: on the WAN routes it withdraws a route whose gateway stops
# answering, but here that is backwards -- the route would vanish exactly when
# the link breaks, the probe would fall through to another table, and netwatch
# would report the link UP while it was down. A probe must keep pointing at the
# broken link to observe that it is broken.
#
# No distances either: one route per table, and the controller never touches
# them.
resource "routeros_ip_route" "probe" {
  for_each = {
    isp0 = { table = "probe-isp0", comment = "PROBEPATH0" }
    isp1 = { table = "probe-isp1", comment = "PROBEPATH1" }
    isp2 = { table = "probe-isp2", comment = "PROBEPATH2" }
  }

  dst_address   = "0.0.0.0/0"
  gateway       = local.gw[each.key]
  routing_table = each.value.table
  comment       = each.value.comment

  depends_on = [routeros_routing_table.this, routeros_ip_address.wan_isp1,
  routeros_ip_dhcp_client.wan]
}

# ---------------------------------------------------------------------------
# Routing rules. ORDER IS EVERYTHING HERE.
#
# Rules match top-down, first match wins, and the last rule is src 10.0.0.0/24
# -- the whole LAN. Anything placed below it is dead config. The groups are
# therefore chained with depends_on so Terraform creates them in sequence:
#
#   probes -> infra -> work -> guest -> household
#
# Within a group order does not matter, because the members of each group are
# mutually exclusive (distinct /32 destinations, or distinct sources), so
# for_each's parallel creation is safe there and only there.
# ---------------------------------------------------------------------------

# 1. Probe pins. These MUST come first: the infra group below matches
# src 10.0.0.1/32 -- the router itself -- which is where probe traffic
# originates. Pinned the other way round, all nine probes would follow main and
# report on whichever link was primary.
#
# lookup-only-in-table, not lookup: no fallthrough. A probe that cannot reach
# its target over its own ISP must fail, not quietly succeed over another.
#
# HARD CONSTRAINT: pins are /32 destination rules, so one address serves exactly
# one ISP. Two rules for the same destination would conflict and both probes
# would measure the same link. Google has only two public addresses, which is
# why ISP2 takes a different operator.
#
# Two transit-crossing targets per link plus one domestic, deliberately. An
# earlier set was mostly domestic (Cloudflare and Quad9 both terminate at
# Kathmandu peering), so the failure that actually matters -- domestic peering
# up, international transit down -- read as 2/3 up and barely moved reputation,
# while everything the household uses is abroad and unreachable. The surviving
# domestic probe is what distinguishes "link dead" from "transit dead".
#
# Targets are measured before adoption, not assumed: Neustar (156.154.70.1) and
# Level3 (4.2.2.2) both have 443 CLOSED and would have been permanent false
# alarms. Candidates must be measured over the link they will be pinned to --
# Comodo read 55ms unpinned via ISP0 and 127ms once pinned to ISP2.
#
# Rate limiting ruled out by measurement, not assumption: across ~47,000 tests
# in a day, zero `refused` and zero `reset`. ICMP is a different matter, and is
# why these are tcp-conn -- at 10 packets/sec Quad9 dropped 40% of pings and
# OpenDNS 16% while both answered TCP cleanly on the same link.
locals {
  probe_pins = {
    # ISP0 -- international, international, domestic
    "8.8.8.8"   = "isp0"
    "76.76.2.0" = "isp0"
    "1.1.1.2"   = "isp0"
    # ISP1
    "8.8.4.4"    = "isp1"
    "45.90.28.0" = "isp1"
    "1.0.0.2"    = "isp1"
    # ISP2
    "208.67.220.220" = "isp2"
    "194.242.2.2"    = "isp2"
    "1.1.1.3"        = "isp2"
  }
}

# Target swaps are done as `moved`, never as destroy-and-create. A pin is keyed
# by its address, so a new address would destroy the old rule and RouterOS would
# append the replacement at the END of the list -- below the infra rule matching
# the router's own source -- and the probe would silently report the primary
# link under the wrong ISP's name. Moving the state entry makes it an in-place
# edit of dst_address, and an edited rule keeps its position.
#
# Only the routing rule moves. The netwatch entry is deliberately left to
# destroy-and-create, because done/failed counters belong to the old target.
# ISP-control tolerates the backwards jump: `:if ($dd <= 0)` skips the sample.
#
# These have all applied and are safe to delete.
moved {
  from = routeros_routing_rule.probe_pin["94.140.14.14"]
  to   = routeros_routing_rule.probe_pin["1.1.1.2"]
}
moved {
  from = routeros_routing_rule.probe_pin["94.140.15.15"]
  to   = routeros_routing_rule.probe_pin["1.0.0.2"]
}
moved {
  from = routeros_routing_rule.probe_pin["94.140.14.15"]
  to   = routeros_routing_rule.probe_pin["1.1.1.3"]
}
moved {
  from = routeros_routing_rule.probe_pin["208.67.222.222"]
  to   = routeros_routing_rule.probe_pin["208.67.220.220"]
}
moved {
  from = routeros_routing_rule.probe_pin["9.9.9.9"]
  to   = routeros_routing_rule.probe_pin["76.76.2.0"]
}
moved {
  from = routeros_routing_rule.probe_pin["149.112.112.112"]
  to   = routeros_routing_rule.probe_pin["45.90.28.0"]
}
moved {
  from = routeros_routing_rule.probe_pin["9.9.9.10"]
  to   = routeros_routing_rule.probe_pin["8.26.56.26"]
}
moved {
  from = routeros_routing_rule.probe_pin["8.26.56.26"]
  to   = routeros_routing_rule.probe_pin["194.242.2.2"]
}

resource "routeros_routing_rule" "probe_pin" {
  for_each    = local.probe_pins
  action      = "lookup-only-in-table"
  dst_address = "${each.key}/32"
  table       = "probe-${each.value}"
  comment     = "${upper(each.value)} probe pin"

  depends_on = [routeros_ip_route.probe, routeros_routing_rule.downloads]
}

# 2. Infra. Each CPE's own subnet has to resolve locally or the CPE becomes
# unreachable for diagnosis, and the router's own traffic -- DNS, NTP, package
# fetches -- stays on main rather than being tiered.
locals {
  infra_rules = {
    "cpe-isp1"  = { dst = "192.168.2.0/24", src = null, comment = "TIER infra (main): ISP1 CPE reachable" }
    "self"      = { dst = null, src = "10.0.0.1/32", comment = "TIER infra (main): the hEX own traffic - DNS, NTP, updates" }
    "lan-local" = { dst = "10.0.0.0/24", src = null, comment = "TIER infra (main): LAN destinations stay local" }
    "cpe-isp0"  = { dst = "192.168.1.0/24", src = null, comment = "TIER infra (main): ISP0 CPE reachable" }
    "cpe-isp2"  = { dst = "192.168.100.0/24", src = null, comment = "TIER infra (main): ISP2 CPE reachable" }
  }
}

resource "routeros_routing_rule" "infra" {
  for_each    = local.infra_rules
  action      = "lookup"
  dst_address = each.value.dst
  src_address = each.value.src
  table       = "main"
  comment     = each.value.comment

  depends_on = [routeros_routing_rule.probe_pin]
}

# 3. Work tier -> ISP0 (Worldlink). Addresses, not MACs: the routing
# rule can only see the source address, which is why the DHCP reservations in
# addressing.tf are load-bearing rather than cosmetic.
locals {
  work_rules = {
    "10.0.0.3/32"   = "TIER work: pve"
    "10.0.0.202/32" = "TIER work: MBP-14 wired"
    "10.0.0.106/32" = "TIER work: office Mac wired"
    "10.0.0.16/28"  = "TIER work: Mac block (real MACs)"
  }
}

resource "routeros_routing_rule" "work" {
  for_each    = local.work_rules
  action      = "lookup"
  src_address = each.key
  table       = "via-isp0"
  comment     = each.value

  depends_on = [routeros_routing_rule.infra]
}

# 4. Guest tier -> ISP2. The sink: the dynamic pool is the only unreserved part
# of the /24, so an unclassified device lands here and takes the smallest link.
# Unknown means guest.
resource "routeros_routing_rule" "guest" {
  action      = "lookup"
  src_address = "10.0.0.160/27"
  table       = "via-isp2"
  comment     = "TIER guest: unreserved pool"

  depends_on = [routeros_routing_rule.work]
}

# 5. Per-ISP Orb sensors -- three containers, each held to one link with no
# fallthrough, so each measures its own ISP and goes dark when that link dies.
# Source-matched, so no real traffic is pinned.
#
# ORDER: these must sit ABOVE the household rule, which matches all of
# 10.0.0.0/24 and would otherwise send all three out via ISP1. RouterOS appends
# new rules at the end, so household depends on these and must be recreated
# after them whenever they are created or replaced:
#
#   terragrunt apply -replace=routeros_routing_rule.household
#
# KNOWN DRIFT: on the router these currently sit BELOW household, so the pins
# are shadowed and all three sensors are measuring via-isp1. Fix with the
# -replace above; do not trust per-ISP Orb data until then.
#
locals {
  orb_sensors = {
    isp0 = "10.0.0.61/32"
    isp1 = "10.0.0.62/32"
    isp2 = "10.0.0.63/32"
  }
}

resource "routeros_routing_rule" "orb" {
  for_each    = local.orb_sensors
  action      = "lookup-only-in-table"
  src_address = each.value
  table       = "probe-${each.key}"
  comment     = "${upper(each.key)} Orb sensor pin"

  depends_on = [routeros_routing_rule.guest]
}

# 6. Household tier -> ISP1. The catch-all, necessarily last: it matches the
# entire LAN and would shadow every rule above it.
#
# ISP1 is the largest link at 400 Mbps, which is what this tier wants. Work is
# isolated on ISP0 so nothing here competes with it; guests sit on ISP2 so
# nothing they do competes with the house.
#
# ISP1 is also the least reliable -- handled by the control loop rather than
# designed around. The controller yields a degraded link, so the household
# follows ISP1's fallback chain while it is bad and returns when reputation
# clears. Capacity is this tier's priority; availability is the loop's job.
resource "routeros_routing_rule" "household" {
  action      = "lookup"
  src_address = "10.0.0.0/24"
  table       = "via-isp1"
  comment     = "TIER household: everything else"

  depends_on = [routeros_routing_rule.orb]
}
