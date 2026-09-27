# Incidents

Postmortems for the larger incidents, and short entries for the smaller ones.

## Postmortems

| Postmortem | Summary |
|---|---|
| [ISP0 optical fault](postmortems/isp0-optical-fault.md) | Worldlink drop at -27 to -31 dBm for eight weeks; fixed 20 Sep by moving to the newer distribution box |
| [Pole cut](postmortems/pole-cut.md) | Vianet and NTFiber cut on one shared pole, 23–26 Sep; 64 h on one link |
| [Controller never decided](postmortems/controller-never-decided.md) | Netwatch-invoked scripts cannot persist `:global`; no decisions for days |
| [Failover off after reboot](postmortems/failover-off-after-reboot.md) | Controller restarted in `SHADOW`; 12½ h without failover |

## The 801 ceiling

**What happened:** every link's reputation converged to exactly **801** after its first blemish and stayed there. `reputation × capacity` degenerated into static capacity ordering; failover worked, quality-based selection did not.

**Cause:** reputation was per-mille (0–1000) and recovered with `(r * 995 + 1000 * 5) / 1000`. At `r = 801` that is `801995 / 1000`, which truncates to 801.

**Fix:** reputation is held per-million, so the per-tick increment sits above the truncation floor. See [Routing and failover](02-routing-and-failover.md). Two links sitting at exactly 801 was the visible clue; treat round numbers in telemetry with suspicion.

## Unshaped upload after the PPPoE migration

**What happened:** after ISP1 moved off PPPoE, Vianet's upload ran with no fq_codel. It showed only as latency under load, not in throughput tests, and was found by auditing a stale export.

**Cause:** the change updated the packet marks but not the queue tree; `ul-isp1` stayed parented to the deleted interface.

**Fix:** the configuration became declarative Terraform, so changing a link is one attribute and dependent resources follow. See [`../terraform/queues.tf`](../terraform/queues.tf) and [Decisions](05-decisions.md).

## A destroy that cut its own path

**What happened:** `terraform destroy` removed the interface list members, 3 of 5 bridge ports and half the routing, then lost its connection. It was one resource short of deleting `10.0.0.1/24`, the address it was talking to.

**Cause:** Terraform managed the bridge, ports and LAN address it arrived through.

**Fix:** the management path (bridge, wired ports, `10.0.0.1/24`) is deliberately unmanaged, a documented precondition like the user accounts. See [the bootstrap](../terraform/README.md#the-bootstrap).

## Port 22 "filtered" by the ISP (disproven)

**DISPROVEN. The ISP does not filter port 22.**

**What happened:** outbound SSH to two destinations timed out on port 22 while other ports connected, and pinning the source to another ISP worked. I concluded the provider filtered port 22.

**Cause of the wrong diagnosis:** tests minutes apart on a link with a known intermittent fault cannot tell "filtered" from "lossy". A TCP traceroute had already reached the destination on port 22, and I under-weighted it because it arrived after the conclusion.

**Fix:** the record is retracted here. The endpoint workarounds (`ssh.github.com:443`, SSM) stay, since a link-pinned route would be undone by the next failover. Do not reopen without new, simultaneous evidence.

## A false "not enforcing" alert

**What happened:** `ControllerNotEnforcing` fired twice on its first day, for 7½ and 2 minutes, while every heartbeat in the router log said `ENFORCE`.

**Cause:** `isp-watch` took the mode from the last log line containing `ISP-control`. Every route change the controller makes also logs a `system,info` line naming `script:ISP-control`, with no mode, so after each failover the mode read as unknown, and the alert counted unknown as not enforcing. The event log had shown it since 9 October as unexplained "controller enforcing again" lines.

**Fix:** the mode is read only from the heartbeat's own prefix, and unknown now raises `ControllerUnobserved` after 20 minutes instead. Checked against the router's log: 1,212 positions read unknown before, none after the first heartbeat.

## Fifteen warnings on a zero-change run

**What happened:** a converged, no-op apply printed fifteen warnings, enough to train skimming.

**Cause:** the RouterOS provider warns on every field it reads but does not model; about half describe real configuration Terraform cannot see.

**Fix:** `-compact-warnings`, set once in [`../terraform/terragrunt.hcl`](../terraform/terragrunt.hcl), puts one line each under the plan summary.
