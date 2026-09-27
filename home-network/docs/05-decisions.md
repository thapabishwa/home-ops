# Decisions

The choices that shaped the network, and what was rejected.

### Three consumer lines instead of one business line

Three consumer lines with second-scale failover.

- **Why:** a support contract shortens fault response; it doesn't keep a link up.
- **Rejected:** one business plan (Worldlink Biz24 Grow): costlier, no second path.
- **Cost:** no contractual recourse. Redundancy is only as real as the physical independence, and there are two domains rather than three ([Architecture](01-architecture.md)).
- **Revisit:** if the [objective](../README.md) is missed because of time in a provider's repair queue, which an SLA reaches, rather than a shared physical path, which it doesn't.

| | per year | per month |
|---|---|---|
| ISP0 Worldlink, 400 Mbps | ~Rs 16,500 | |
| ISP1 Vianet, 400 Mbps | Rs 15,600 | |
| ISP2 NTFiber, 200 Mbps | ~Rs 16,500 | |
| **three lines, 1,000 Mbps** | **~Rs 48,600** | ~Rs 4,050 |
| Biz24 Grow (incl. VAT) | Rs 73,450 | ~Rs 6,100 |
| hardware, one-off: hEX 11,000, TL-SG108E 5,000, 7 mini DC UPS 14,000 | **Rs 30,000** | |

About **34 %** cheaper; the saving pays for the hardware in about fifteen months.

### Per-device-class tiers instead of load balancing

Each device class gets one link and moves only when it degrades.

- **Why:** one TCP flow never exceeds one link.
- **Rejected:** PCC, which is incompatible with FastTrack.
- **Result:** FastTrack stays on, and a failure affects one class ([Routing and failover](02-routing-and-failover.md)).
- **Revisit:** if one class needs more than its link's shaped rate for sustained periods.

### Downloads split across ISP1 and ISP2

qBittorrent alone is split across two links.

- **Why:** it has hundreds of independent bulk connections that tolerate a rotating source address.
- **Rejected:** a wider split (Slack, Zoom and logins tie a session to one address); adding ISP0 (the seeder is the ceiling, and the largest flow lands on the work link).
- **Cost:** one host leaves FastTrack (`connection_mark = "no-mark"`) and pays a CPU tax.

### Reputation scoring instead of binary up/down

An asymmetric moving average per link.

- **Why:** probe state alone missed ISP0's chronic fault, and a symmetric average washes out a blackout.
- **Rejected:** probe state alone; equal weighting; a tier cooldown timer.
- **Cost:** the constants are reasoned, not fitted. The global primary still keeps a timer: a 110 % margin held for 15 minutes.
- **Revisit:** if [replaying the history](../tools/replay/replay.py) shows the scoring yielding later, or returning worse links, than probe state alone would have.

### The controller runs from the scheduler

Netwatch measures; one scheduled script decides.

- **Why:** a netwatch-invoked script can't persist a `:global`.
- **Rejected:** decisions in `up-script` / `down-script`, the [controller that never decided](postmortems/controller-never-decided.md).

### The management path is unmanaged

The bridge, its four ports and `10.0.0.1/24` stay out of Terraform.

- **Why:** owning them let a `destroy` cut Terraform's own path.
- **Rejected:** full coverage.
- **Cost:** a [bootstrap](../terraform/README.md#the-bootstrap) precondition with no drift detection. A change there makes the router unreachable anyway.

### User accounts are not in Terraform

I create accounts by hand.

- **Why:** `routeros_system_user` carries a password, and state is in a public repo.
- **Rejected:** managed users; using `admin` for automation.
- **Cost:** service accounts are a documented post-rebuild step.
- **Revisit:** if state moves to an encrypted backend.

### One Terragrunt unit, no modules

One unit, one directory, plain `terragrunt apply`.

- **Why:** there is one network: one laptop, one hypervisor, eleven MACs, measured line rates.
- **Rejected:** `modules/` + `live/`; stacks with cross-state dependencies.
- **Revisit:** if a second MikroTik appears.

### A manual bootstrap instead of import tooling

Seven Winbox lines, then `apply`.

- **Why:** a reset router has no address and no credential.
- **Rejected:** a Python importer; a self-surviving bootstrap script. Both worked; neither was needed once the management path was unmanaged.
- **Result:** Terraform's address never moves.

### ISP1 holds a static address

- **Why:** ISP1's dhcp-client sent nine DISCOVERs over 24 s with no reply; the other two bind on identical config.
- **Rejected:** DHCP for uniformity.
- **Revisit:** the sniffer command that would overturn this sits beside the resource.

### When to replace a provider

The hEX owns the LAN, so a provider is only a slot: a VLAN and a switch port. Outage length isn't the trigger; ISP1's 65-hour [pole cut](postmortems/pole-cut.md) was handled well.

I leave only when both hold:

- **Measurable recurrence:** dropouts per day in `isp-events.log`, a reputation that never recovers, or a worsening optical level.
- **Support has stopped producing progress:** canned replies, reboot instructions, undated promises.

Either alone means keep escalating. Rejected: leaving after one long outage; annual terms.

Then:

- The swap touches only the slot ([runbook](07-runbooks.md#swap-a-provider)).
- New providers start on short terms. A quarter cost Rs 6,544 against Rs 22,000 a year, about 19 % more annualised, for the option to leave in three months. ISP0 is on this probation after its [optical fault](postmortems/isp0-optical-fault.md).
- Ask which pole route it uses; one on the shared pole adds no failure domain.
- Ask which distribution box, and check the level at install. Near -27 dBm on day one is a fault.
- Measure the new slot from day one with the same probes.
