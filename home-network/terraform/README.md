# Terraform for the hEX

Implementation notes for the router configuration. The reasoning is in [the overview](../README.md) and [Decisions](../docs/05-decisions.md).

One Terragrunt unit, 166 resources, converged: a re-run reports `0 added, 0 changed, 0 destroyed`.

```sh
terragrunt plan
terragrunt apply
```

## Who owns what

The controller rewrites route distances every tick. Terraform and the controller manage the same objects but own different fields:

| | this repo owns | `ISP-control` owns |
|---|---|---|
| `/ip route` | which routes exist: gateway, table, comment | `distance` |
| `/system script` | that it exists, its name, policy and body | (nothing) |
| `/system scheduler` | interval, on-event, policy | `start-date` / `start-time` |

Each carries `lifecycle { ignore_changes = [...] }` naming the field the other side owns. `plan` stays quiet during failover, so any diff is a real change: a route added, removed or repointed, or a manual edit in WinBox.

## Layout

One directory, one unit, one command.

```
terragrunt.hcl      provider + backend generation, reads credentials.hcl
credentials.hcl     the only place credentials live (gitignored)

vlans.tf            the 4 VLANs on the trunk, and the remote-LAN bridge port
interfaces.tf       WAN/LAN interface lists and their members
addressing.tf       WAN addresses, DHCP server and reservations, DNS
firewall.tf         filter chains, masquerade per WAN, packet marks
queues.tf           fq_codel trees, shaped per link
routing.tf          routing tables, default routes, policy rules
netwatch.tf         the nine probes
script.tf           the controller and its scheduler
system.tf           identity, clock, NTP, read-only API groups
```

Also present: `downloads.tf` (the ISP1/ISP2 download split), `host_pin.tf` (per-host ISP pins), `logging.tf` (log retention), `services.tf` (management services).

## What isn't managed, and why

| object | why |
|---|---|
| `bridge-lan`, `ether2`–`ether5` bridge ports, `10.0.0.1/24` | Terraform reaches the router through these six. Managing them let a `destroy` stop one resource short of removing the address it was talking to. No drift detection; a change announces itself by making the router unreachable |
| user accounts | `routeros_system_user` carries a password, which would land in git history and `terraform.tfstate` in a public repo. The groups are managed; accounts are made by hand |
| `/tool sniffer` | leftover debugging arguments, and the provider rejects `udp` for `filter_ip_protocol` |

`lan-remote` is managed, because nothing reaches the router over VLAN 90.

## Ordering constraints

RouterOS evaluates firewall chains and routing rules top-down, first match wins; Terraform creates in parallel. Both are chained with `depends_on`:

- **Filter rules:** `drop everything else from WAN` above `accept all from LAN` would lock the LAN out of the router.
- **Routing rules:** the last rule matches `src 10.0.0.0/24`, the whole LAN; anything after it is dead config. Order: probes → infra → work → guest → household.

Within each group members are mutually exclusive (distinct `/32` destinations or non-overlapping sources), so `for_each` order is safe there only.

## Running it

`credentials.hcl` (gitignored):

```hcl
locals {
  router_url      = "http://10.0.0.1"
  router_username = "admin"
  router_password = "..."
}
```

The address never moves, because the management path isn't managed.

```sh
terragrunt plan
terragrunt apply
```

- `terraform_binary = "terraform"` is set in `terragrunt.hcl`. Terragrunt 1.0 defaults to OpenTofu, which resolves `registry.opentofu.org` while the lock file pins `registry.terraform.io`. The provider is cached under the latter, so `init` works offline, the normal state while rebuilding the router.
- `router_url` is an IP because `hex.internal` is served by this router.

## The bootstrap

Once per router lifetime, in Winbox, which connects by MAC and needs no IP:

```
/system/reset-configuration no-defaults=yes skip-backup=yes

/interface/bridge/add name=bridge-lan
/interface/bridge/port/add bridge=bridge-lan interface=ether2
/interface/bridge/port/add bridge=bridge-lan interface=ether3
/interface/bridge/port/add bridge=bridge-lan interface=ether4
/interface/bridge/port/add bridge=bridge-lan interface=ether5
/ip/address/add address=10.0.0.1/24 interface=bridge-lan
/user/set admin password="..."
```

Use `no-defaults`. A plain reset leaves defconf's `bridge` holding `ether2`–`ether5`; those four ports then fail with `device already added as bridge port`.

Recreate the service accounts. Without them every container that talks to the router logs `login failure for user homepage ... via rest-api` once a minute. Passwords are cluster Secrets: `homenet/homenet-credentials` and `monitoring/mktxp-credentials`.

```
/user/add name=homepage group=dashboard  password="..." address=10.0.0.21/32
/user/add name=mktxp    group=monitoring password="..." address=10.0.0.20/31
```

| account | used by | source |
|---|---|---|
| `homepage` | homenet scripts (REST), pinned to the worker by their volume | `10.0.0.21/32` |
| `mktxp` | exporter (binary API, 8728), either node | `10.0.0.20/31` |

The `monitoring` group has `api` without `rest-api`.

Give the workstation a static `10.0.0.50/24` on the port cabled to the router and put `ether1` on the switch trunk. From here it's `terragrunt apply`.

### Why the bootstrap can't be automated

- Terraform needs an address and a credential. A `no-defaults` reset has neither; defconf has `192.168.88.1` but a blank password, and REST answers `401`. Setting a password is always manual.
- Winbox reaches a router with no IP over MAC-Telnet (raw layer 2). The provider speaks only REST (TCP/80) or the binary API (TCP/8728) to one `hosturl`; there is no MAC transport.
- The IPv6 link-local address is the nearest equivalent. Untested; needs the `ipv6` package, provider support for the `%25<iface>` zone, and is tied to the workstation's interface name:

```
AA:BB:CC:DD:EE:FF  ->  fe80::a8bb:ccff:fedd:eeff
```

```sh
curl -s -o /dev/null -w '%{http_code}\n' -m 5 -u admin:PASSWORD \
  'http://[fe80::a8bb:ccff:fedd:eeff%25en11]/rest/system/resource'
```

`200` would mean it works as `router_url`. It fixes nothing, since `10.0.0.1` no longer moves. Keeping defconf's `bridge` saves four `add` lines but costs four `remove` lines for its DHCP server, masquerade and filter chain.

### If you lose the router

Discovery is scoped to the `LAN` interface list. If `interfaces.tf`'s list members are destroyed, the Winbox neighbour list goes empty. MAC-Winbox (`/tool/mac-server`) is untouched by this config: type the bridge MAC into Winbox's *Connect To* field.

## What this won't catch

Logic bugs in the controller: a reputation ceiling, a mode that defaults the wrong way after a reboot, a flush on the wrong condition. Terraform verifies the bytes on the router, not that they're correct. The body comes from `scripts/isp-control.src`, and RouterOS doesn't parse a script until it runs. After an apply that changes it, run it once and read the output:

```
/system script run ISP-control
```
