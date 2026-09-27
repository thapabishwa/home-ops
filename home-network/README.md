# Home network

A multi-WAN home network that is also my office uplink: I work from home full time, so a dropped call or a dead SSH session is lost work.

## What it is

- **Three ISPs, all behind CGNAT:** ISP0 Worldlink 600/300 (400/200 from 2 November 2026), ISP1 Vianet 400/200, ISP2 NTFiber 200/100. Rules refer to the slot (`isp0`, `isp1`, `isp2`), never the provider, so replacing one touches a handful of values.
- **One MikroTik hEX** terminates all three over **one 30 m gigabit trunk**, each ISP a VLAN tag. The CPEs sit downstairs, outside the living space, so technicians never enter the house.
- **Device tiers:** work devices prefer ISP0, known household devices ISP1, guests and anything unrecognised ISP2. Every tier's routing table holds all three links.
- **A controller** (a scheduler script on the router) scores each link from nine port-443 probes and rewrites route distances when one degrades.
- **Declarative config:** everything is Terraform; a re-run reports `0 added, 0 changed, 0 destroyed`.

## Key numbers

| | |
|---|---|
| Failover off a dead link | **~2 s** measured, 3 s worst case; a video call survives |
| Aggregate throughput cap | **~940 Mbps**, set by the shared trunk |
| Longest double outage | **64 h**, ISP1 and ISP2 cut together at one shared pole, 23 to 26 September 2026 |
| ISP0 optical fault | -27 dBm at install, -31 dBm at worst, repaired to -17 dBm on 20 September 2026 |

## Objective

The work tier has a usable path **99.9 %** of the time over a rolling 30 days: about **43 minutes** a month of error budget. Failover, spares and the [next steps](docs/06-risks-and-next.md) are judged against it. The indicator and how to measure it are in [Monitoring](docs/03-monitoring.md).

**Not met yet.** Measured over 19 September to 14 October: 96.2 %, 85 % of the shortfall from the [pole cut](docs/postmortems/pole-cut.md). Since the 28 September probe and controller changes, 99.77 %: about 100 minutes a month.

## Pages

- [Architecture](docs/01-architecture.md): trunk, VLANs, ISPs, CGNAT, shaping
- [Routing and failover](docs/02-routing-and-failover.md): tiers, control loop, measured failover
- [Monitoring](docs/03-monitoring.md): probes, counters, alerts, notifications
- [Incidents](docs/04-incidents.md)
- [Decisions](docs/05-decisions.md)
- [Risks and next steps](docs/06-risks-and-next.md)
- [Runbooks](docs/07-runbooks.md)
- [Implementation](terraform/README.md): the Terraform, one unit; the controller is [`terraform/scripts/isp-control.src`](terraform/scripts/isp-control.src)

Postmortems:

- [ISP0 optical fault](docs/postmortems/isp0-optical-fault.md)
- [Pole cut: 64 hours on one link](docs/postmortems/pole-cut.md)
- [A controller that never decided](docs/postmortems/controller-never-decided.md)
- [Failover off after a reboot](docs/postmortems/failover-off-after-reboot.md)
