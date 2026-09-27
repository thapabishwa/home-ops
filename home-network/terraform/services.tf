# Management services. Declared so a rebuild restores them and `plan` reports
# drift -- a `no-defaults` reset otherwise leaves service state to RouterOS's
# defaults, which you discover by something failing.
#
# These are `set` operations, not `add`: RouterOS ships a fixed list and
# `numbers` names the one to modify.
#
# Chicken-and-egg: Terraform cannot enable the API it connects through, so
# `www` must already be on before the first apply. This keeps it on and turns
# off what should never be.

locals {
  services = {
    # REST on 80 -- Terraform and the Caddy container's scripts both use this.
    www = { port = 80, disabled = false }

    # Binary API on 8728, scraped by mktxp. The `monitoring` group has `api`
    # without `rest-api` to match.
    api = { port = 8728, disabled = false }

    # The recovery path: Winbox connects by MAC when the router has no IP at
    # all, which is the only way back after a no-defaults reset. Do not disable
    # without a serial cable and a plan.
    winbox = { port = 8291, disabled = false }

    ssh = { port = 22, disabled = false }

    telnet = { port = 23, disabled = true }
    ftp    = { port = 21, disabled = true }

    # Both need a certificate the router does not have. Off rather than
    # half-configured -- a TLS listener with an untrusted cert teaches people
    # to click through warnings.
    www-ssl = { port = 443, disabled = true }
    api-ssl = { port = 8729, disabled = true }
  }
}

# Deliberately no `address` restriction. The input chain already drops the WAN
# list, and during a rebuild the workstation sits on a temporary subnet -- an
# address pin would lock WebFig out exactly when it is needed. Winbox-over-MAC
# would still work; WebFig would not.
resource "routeros_ip_service" "this" {
  for_each = local.services
  numbers  = each.key
  port     = each.value.port
  disabled = each.value.disabled
}
