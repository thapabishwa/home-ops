# Addresses, DHCP and DNS.


# ISP1 is static because it was tested, not overlooked: a dhcp-client here sent
# nine DISCOVERs over 24s and got nothing back, while the other two links bind
# on byte-identical config behind the same drop rule. Vianet's CPE does not
# answer DHCP on that port.
#
# Do not "simplify" this to a dhcp-client without re-testing:
#
#   /tool/sniffer/quick interface=wan-isp1 port=bootpc,bootps
#
# An OFFER coming back is the only thing that should change this.
resource "routeros_ip_address" "wan_isp1" {
  address   = "192.168.2.2/24"
  interface = local.wan_iface["isp1"]
  network   = "192.168.2.0"
}

# add_default_route=no is the whole point: ISP-control owns every default
# route's distance, and a client installing its own would fight it, appearing
# and disappearing with the lease. use_peer_dns=false for the same reason --
# DNS stays on Cloudflare and unpinned so an ISP outage cannot take resolution
# with it.
resource "routeros_ip_dhcp_client" "wan" {
  # RouterOS names dhcp-clients itself (client1, client2, ...); the provider
  # exposes no name attribute, so these keys are Terraform labels only.
  for_each = {
    isp0 = { comment = "ISP0 Worldlink WAN address" }
    isp2 = { comment = "ISP2 NTFiber WAN address" }

    # TEMPORARY, for the open Vianet ticket -- delete this line when it closes.
    # Their CPE receives DISCOVERs and never answers, so this one stays
    # `searching` while the two above stay `bound` on identical config. That
    # contrast is the demonstration, and it is the whole reason it is here.
    isp1 = { comment = "ISP1 Vianet DHCP test - no OFFER, ticket open" }
  }
  interface         = local.wan_iface[each.key]
  add_default_route = "no"
  use_peer_dns      = false
  comment           = each.value.comment
}

# Only .160-.191 is dynamic; everything else is reserved or static. This IS the
# guest tier: an unknown device lands in this pool, a routing rule matches the
# pool, and it leaves over ISP2 without anyone classifying it.
resource "routeros_ip_pool" "lan" {
  name   = "lan-pool"
  ranges = ["10.0.0.160/27"]
}

# dynamic_lease_identifiers must be explicit. RouterOS 7.20+ requires it
# non-empty and the provider sends every managed attribute on PATCH, so
# omitting it works on create and then fails on the next update with
# "at least one dynamic lease identifier should be specified".
#
# The tokens are `client-mac` and `client-id`, NOT `mac-address`, which REST
# rejects. Affects dynamic leases only; the reservations below match on
# mac_address regardless.
resource "routeros_ip_dhcp_server" "lan" {
  name                      = "lan-dhcp"
  dynamic_lease_identifiers = "client-mac,client-id"
  interface                 = local.bridge
  address_pool              = routeros_ip_pool.lan.name
}

resource "routeros_ip_dhcp_server_network" "lan" {
  address    = "10.0.0.0/24"
  gateway    = "10.0.0.1"
  dns_server = ["10.0.0.1"]
}

# Reservations ARE the tiering mechanism: a device's address decides which ISP
# it leaves by, so the address must be predictable -- which is why MAC
# randomisation had to be turned off on the Macs first. The .16/28 block holds
# real Mac addresses and is matched as a block by one routing rule.
#
# The table lives in leases.hcl, gitignored: this repo is public and the
# reservations name people's devices.
variable "leases" {
  description = "DHCP reservations, keyed by address. Supplied from leases.hcl, which is gitignored."
  type = map(object({
    mac       = string
    client_id = string
    comment   = string
  }))
}

resource "routeros_ip_dhcp_server_lease" "this" {
  for_each    = var.leases
  address     = each.key
  mac_address = each.value.mac
  client_id   = each.value.client_id
  comment     = each.value.comment
  server      = routeros_ip_dhcp_server.lan.name
}

# Cloudflare, deliberately NOT pinned to any ISP. The probe rules use
# lookup-only-in-table, which has no fallthrough, so pinning a resolver to one
# link would turn a single-ISP outage into a total one. For the same reason no
# probe target may ever be a resolver in use.
resource "routeros_ip_dns" "this" {
  servers               = ["1.1.1.1", "1.0.0.1"]
  allow_remote_requests = true
}

locals {
  dns_static = {
    "router.internal"      = { address = "10.0.0.1", comment = "hEX router (was opnsense.internal)" }
    "hex.internal"         = { address = "10.0.0.1", comment = "hEX router" }
    "switch.internal"      = { address = "10.0.0.2", comment = "TL-SG108E" }
    "pve.internal"         = { address = "10.0.0.3", comment = "Proxmox host" }
    "ca.internal"          = { address = "10.0.0.30", comment = "household CA download, plain HTTP on purpose" }
    "jellyfin-ct.internal" = { address = "10.0.0.10", comment = "Jellyfin direct, bypasses proxy" }
    "qbit-ct.internal"     = { address = "10.0.0.11", comment = "qBittorrent direct, bypasses proxy" }
    "unmanic-ct.internal"  = { address = "10.0.0.12", comment = "Unmanic (CT 105) direct, bypasses proxy" }
    "talos-cp-1.internal"  = { address = "10.0.0.20", comment = "Talos control plane (VM 110)" }
    "talos-w-1.internal"   = { address = "10.0.0.21", comment = "Talos worker (VM 111)" }
    "k8s.internal"         = { address = "10.0.0.20", comment = "Kubernetes API endpoint" }
    "macbook-pro.internal" = { address = "10.0.0.202", comment = "work - wired MacBook" }
    "mac.internal"         = { address = "10.0.0.105", comment = "work - Mac (wifi)" }
    "home.internal"        = { address = "10.0.0.30", comment = "via Traefik (k8s)" }
    "flux.internal"        = { address = "10.0.0.30", comment = "via Traefik (k8s) - Flux web UI" }
    "prometheus.internal"  = { address = "10.0.0.30", comment = "via Traefik (k8s) - Prometheus UI, not for guests" }
    "grafana.internal"     = { address = "10.0.0.30", comment = "via Traefik (k8s) - household Grafana, not for guests" }
    "dash.internal"        = { address = "10.0.0.30", comment = "via Traefik (k8s) - Homepage feeds" }
    "proxmox.internal"     = { address = "10.0.0.30", comment = "via Traefik (k8s)" }
    "tplink.internal"      = { address = "10.0.0.30", comment = "via Traefik (k8s)" }
    "jellyfin.internal"    = { address = "10.0.0.30", comment = "via Traefik (k8s)" }
    "qbit.internal"        = { address = "10.0.0.30", comment = "via Traefik (k8s)" }
    "unmanic.internal"     = { address = "10.0.0.30", comment = "via Traefik (k8s)" }
  }
}

resource "routeros_ip_dns_record" "static" {
  for_each = local.dns_static
  name     = each.key
  address  = each.value.address
  type     = "A"
  comment  = each.value.comment
}