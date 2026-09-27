# System settings, management access and monitoring exposure.

resource "routeros_system_identity" "this" {
  name = "hEX-router"
}

resource "routeros_system_clock" "this" {
  time_zone_name = "Asia/Kathmandu"
}

# Two operators, for the same reason the probes use three. Every timestamp in
# isp-events.log is read against this clock.
resource "routeros_system_ntp_client" "this" {
  enabled = true
  servers = ["pool.ntp.org", "time.cloudflare.com"]
}

# Read-only API access, so the things watching this router cannot change it.
# mktxp scrapes every 30s and the dashboard polls continuously; either holding
# write access would make a compromised LAN container a compromised router.
#
# The !negations are NOT redundant with omitting them -- RouterOS grants some
# policies by default, so a group defined only by what it allows can still
# carry write or password.
resource "routeros_system_user_group" "dashboard" {
  name    = "dashboard"
  comment = "read-only REST for Homepage"
  policy = [
    "read", "api", "rest-api",
    "!local", "!telnet", "!ssh", "!ftp", "!reboot", "!write", "!policy",
    "!test", "!winbox", "!password", "!web", "!sniff", "!sensitive", "!romon",
  ]
}

# No rest-api: mktxp speaks the binary API on 8728. Granting both would widen
# the surface for no gain.
resource "routeros_system_user_group" "monitoring" {
  name    = "monitoring"
  comment = "read-only API for mktxp on CT104"
  policy = [
    "read", "api",
    "!local", "!telnet", "!ssh", "!ftp", "!reboot", "!write", "!policy",
    "!test", "!winbox", "!password", "!web", "!sniff", "!sensitive",
    "!romon", "!rest-api",
  ]
}

# The USER accounts in these groups are deliberately absent and always will be:
# routeros_system_user carries a password, and a password in Terraform is a
# password in git history and in terraform.tfstate. The groups are the
# reviewable part. Accounts are made by hand; see README.md.

# SNMP feeds mktxp. ether1 is in the WAN list and the input chain drops it.
resource "routeros_snmp" "this" {
  enabled  = true
  contact  = "homelab"
  location = "top floor rack"
}

# NOT MANAGED: the SNMP community. RouterOS ships a built-in `public` that can
# only be modified, never created, so apply fails with "community with the same
# name already exists!". Managing it would need an import before the first
# apply for one object. SNMP is already unreachable from outside; if you want
# the restriction anyway:
#
#   /snmp/community/set [find default=yes] addresses=10.0.0.0/24

# LAN only -- on the WAN list this would answer MNDP and CDP to the three CPEs.
resource "routeros_ip_neighbor_discovery_settings" "this" {
  discover_interface_list = "LAN"

  depends_on = [routeros_interface_list.this]
}

# Advisory only; nothing depends on it. The netwatch probes and the controller
# are the real signal. Kept because its guesses show up in Winbox and are
# occasionally useful when a VLAN is misconfigured.
resource "routeros_interface_detect_internet" "this" {
  detect_interface_list = "all"
}

# NOT MANAGED: /tool sniffer. The running config carries file-limit=8000KiB and
# filter-ip-protocol=udp from an old debugging session. The sniffer is stopped,
# so these are arguments it would use rather than settings affecting traffic,
# and the provider rejects "udp" for filter_ip_protocol. Clear it on the router:
#
#   /tool/sniffer/set file-limit=1000KiB filter-ip-protocol=""
