# Runbooks

Steps for each alert and procedure, and the drills that test the other pages' claims.

## Where everything is

| what | where | how to reach it |
|---|---|---|
| hEX router | `10.0.0.1` | Winbox (by MAC, works with no IP), or REST on port 80 |
| TL-SG108E switch | `10.0.0.2` | web UI only; one session at a time |
| event watcher, loss sampler, `isp-events.log` | Talos cluster, namespace `homenet` (CronJobs `isp-watch`, `isp-log`) | `kubectl -n homenet exec deploy/dash-agent -- tail /data/log/isp-events.log` |
| web names (`home`, `dash`, `flux`, `prometheus`, `grafana`, `ca`, `jellyfin`, `qbit`, `proxmox`, `tplink` `.internal`) | Traefik on the cluster, `10.0.0.30` | [`kubernetes/`](../../kubernetes/README.md); everything behind them runs in the cluster except pve and the switch, which are also reachable directly |
| exporter and Prometheus | Talos cluster, namespace `monitoring` | alerts are evaluated here and delivered by Grafana Cloud; see [`kubernetes/`](../../kubernetes/README.md) |
| Orb sensors, one per ISP | `10.0.0.61` ISP0, `.62` ISP1, `.63` ISP2 | Orb's app; each is held to its ISP by a routing rule |
| router configuration | this repo, [`terraform/`](../terraform/) | `terragrunt plan` / `apply` |
| router password | `terraform/credentials.hcl` | gitignored; keep a copy off the router |
| DHCP reservations | `terraform/leases.hcl` | gitignored; keep a copy off the router |
| controller source | [`terraform/scripts/isp-control.src`](../terraform/scripts/isp-control.src) | deployed by `terragrunt apply` |

On the router terminal:

```
/log print where topics~"warning" and message~"ISP-"   # every decision and probe line, nothing else
/log print where message~"ISP-control"     # heartbeat and decisions
/log print where message~"ISP-probe"       # which probe failed, since when, and why
/ip route print where dst-address=0.0.0.0/0  # current distances, per table
/tool netwatch print                         # the nine probes
/system scheduler print where name=isp-control
```

The `warning` topic filters out script-change entries, which carry the whole body.

## For anyone in the house

**The internet is down on every device.**

1. Check a phone on mobile data. If it doesn't work either, the problem is wider than this house. Wait.
2. Look at the three provider boxes downstairs. If their lights show a connection, the fault is the switch, the cable or the router.
3. Power-cycle the **switch**, then the **router** (the small black MikroTik upstairs). Wait three minutes. Nothing needs to be set.
4. Still down: use a provider box's own Wi-Fi or a phone hotspot.

**Never press the reset button on the switch.** It wipes the configuration and takes down all three lines until rebuilt by hand.

## Alerts

### `ISPDown`: one link is down

1. Confirm the move: the latest `ISP-control` line shows that link's `up=0` and a `flush:` entry, and `yield` has that link's bit set.
2. Check the provider's box. No optical/PON light means fibre; for ISP0, check receive power in the ONT dashboard.
3. Report it with the start time from `isp-events.log`.
4. If it's the second link down, expect `NoRedundancy`.

### `ISPDegraded`: some probes failing on one link

1. Run `/log print where message~"ISP-probe"`. Same target failing on several links at once: the target's problem. Nothing to do.
2. One link only: watch its reputation in the heartbeat. Below 500k the tier yields on its own.
3. Read the `ISP-probe-why` line for that probe.

### Why a probe failed

`ISP-probe-why` re-tests each down probe once over the same pinned path:

| log says | means |
|---|---|
| `retest failed, timeout: failure: timeout connecting` | packets are being lost on the path: the link |
| `retest failed, refused: failure: Connection refused` | the target is rejecting us: rate limiting, or the target itself |
| `retest failed, reset: ...` | the same, closed mid-handshake |
| `retest connected` | the path worked seconds later: a transient, or netwatch misfired |
| `retest connected (...)` | TCP connected; the error came after it, e.g. `Status 308, Permanent Redirect` from Cloudflare, TLS, or an HTTP error page |
| anything mentioning permissions | the script's policy is wrong, not the link |

These strings are verified against a dead address and a closed port, not a real outage. Confirm with the sniffer while a probe is down:

```
/tool sniffer quick interface=wan-isp1 ip-address=8.8.4.4 port=443
```

SYNs, no reply: timeout. RST: refusal. No SYN: routing or pin problem.

### `NoRedundancy`: one healthy link left

1. Ready a mobile hotspot for the work laptop.
2. Do not start maintenance, swaps or drills.
3. If the survivor is ISP0, watch its probes; it has the worst fault history.
4. Get a restoration time from the provider that's down.

### `AllWANsDown`: nothing left

1. Work on the mobile hotspot.
2. Provider Wi-Fi works: the fault is the switch, trunk or hEX; see [Replace the switch](#replace-the-switch) or [Replace the router](#replace-the-router). Otherwise it's the providers.
3. This alert may never arrive: it has no path out. See [Risks](06-risks-and-next.md).

### `RouterUnreachable`: the exporter cannot see the hEX

1. WAN state is unknown. If the internet works from a LAN device, restart the exporter: `kubectl -n monitoring rollout restart deployment mktxp`. A down cluster means no alerts at all.
2. Nothing works: treat as `AllWANsDown`, house side.

### `ControllerNotEnforcing`

Heartbeat shows `SHADOW` instead of `ENFORCE`, or `isp-events.log` shows `CRIT`. Failover is off. See [Failover off after reboot](postmortems/failover-off-after-reboot.md).

1. On the router terminal: `:global ispShadow 0`
2. The next line (within 10 s) must read `ENFORCE`. If not, see below.

### `ControllerUnobserved`: nothing can see the controller

1. `kubectl -n homenet get cronjob isp-watch` and `kubectl -n homenet get pods`: is the watcher running, and `dash-agent`?
2. On the router, `/log print where message~"ISP-control (ENFORCE|SHADOW)"`. No heartbeat in the last 15 minutes means the controller is not logging: treat as `ControllerStalled`.
3. Heartbeats present but the alert firing: the watcher's parsing, see [Incidents](04-incidents.md).

### `ControllerStalled`: the run-count stopped

1. `/system scheduler print where name=isp-control`. Run count should rise every second.
2. Not rising: `terragrunt apply` restores the scheduler.
3. Rising but no log: run `/system script run ISP-control` and read the error.

## Procedures

### Swap a provider

Criteria: [Decisions](05-decisions.md). Nothing on the LAN changes.

1. Confirm the other two links are healthy. Never swap under `NoRedundancy`.
2. Unplug the old CPE. Confirm its tier moved (~2 s), as for `ISPDown`.
3. Connect the new CPE to the **same** switch port.
4. Edit the slot:

   | what | where |
   |---|---|
   | gateway the CPE hands out | [`routing.tf`](../terraform/routing.tf) `local.gw` |
   | static address or DHCP client | [`addressing.tf`](../terraform/addressing.tf) |
   | shaping limits for the new line rate | [`queues.tf`](../terraform/queues.tf) |
   | capacity used for ranking | `caps` in [`isp-control.src`](../terraform/scripts/isp-control.src) |
   | provider name | comments in `vlans.tf` and `routing.tf` |

5. `terragrunt apply`. If `caps` changed, follow [Change the controller](#change-the-controller).
6. Verify: the slot reads `up=3`; the tier returns within about an hour.

### Replace the switch

| port | VLAN | untagged / PVID | role |
|---|---|---|---|
| 1 | 10 | untagged | ISP0 CPE |
| 2 | 20 | untagged | ISP1 CPE |
| 3 | 30 | untagged | ISP2 CPE |
| 4 | 40 | untagged | spare slot |
| 5–7 | 90 | untagged | LAN access |
| 8 | 10, 20, 30, 90, 100 | tagged | trunk to the hEX |

1. Set management to **static** `10.0.0.2` first. On DHCP it once took a lease from a provider's router.
2. Build the VLAN table, then set each port's PVID.
3. Move cables port for port; trunk to hEX `ether1`.
4. Verify: all three links `up=3`; a device on ports 5–7 gets `10.0.0.x`.

The switch has no API; this table is maintained by hand, so check it against the live switch.

### Replace the router

1. Bootstrap the new hEX: the seven Winbox lines in [the Terraform README](../terraform/README.md#the-bootstrap).
2. Restore `credentials.hcl` and `leases.hcl` into `terraform/`.
3. `terragrunt apply`. Works offline with `terraform/.plugin-cache/`; it's gitignored, so a fresh clone needs one online `init`.
4. Recreate `homepage` and `mktxp`; passwords are in cluster Secrets.
5. Verify: `plan` shows no changes, heartbeat reads `ENFORCE`, exporter scrapes.

### Add or rebuild an Orb sensor

Each sensor is a container pinned to one ISP by source address; it goes dark while its link is down.

1. On PVE, create the container with a **static** address (`10.0.0.61/24` ISP0, `.62` ISP1, `.63` ISP2), gateway `10.0.0.1`, DNS `1.1.1.1`. Public DNS keeps lookups on its ISP.
2. Install Orb and link it with the deployment token. The token is a credential; never commit it.
3. If routing rules were recreated, restore order: `terragrunt apply -replace=routeros_routing_rule.household`. The household rule matches the whole LAN and must sit below the sensor rules.
4. Verify in each container: `curl -s https://ifconfig.me` returns a **different** address for each. Duplicates mean a rule is out of order.
5. Disable Orb's speed tests or schedule them outside working hours; they degrade calls.

### Change the controller

1. Edit `terraform/scripts/isp-control.src`.
2. `terragrunt plan`. The diff should touch only the script's `source`.
3. `terragrunt apply`, then `/system script run ISP-control` once. RouterOS doesn't check a script until it runs, so a syntax error applies cleanly and only shows here.
4. Watch three heartbeat lines. Changing the interval, weights or margins retunes the whole scoring system.

## Drills

A claim on the other pages counts as demonstrated only once its row is filled in. What each failover costs by activity is in [Routing and failover](02-routing-and-failover.md).

### Single-link failover

Proves: a tier moves off a dead link fast enough that a call survives.

Expect ~2 s, 3 s worst: probe interval (1.2 s) + timeout (0.5 s) + up to one tick (1 s). Before 28 September: 5 / 13 / 23 s.

1. From a work device, join a real call and run [`tools/failover-drill.py`](../tools/failover-drill.py) `ISP0 --return`. It probes every 0.2 s, reads the router log, and prints the row.
2. Unplug the CPE at a random moment and press Enter as you do.
3. Answer whether the call survived.
4. Plug it back in and time the return. A one-tick blip leaves reputation near 700k, ~15 min back (ISP1, 26 September: 13½); 90 s down leaves ~30k, ~50 min. `main`'s primary adds the 15-minute hold.
5. Three runs per link, at different moments.

| date | link pulled | traffic gap (s) | controller acted (s) | call survived | return time |
|---|---|---|---|---|---|
| 2026-09-27 07:08 | ISP0 | 14.6 | in the same tick traffic returned | no | stopped at 12 min; ~52 min computed |
| 2026-09-28 23:11 | ISP0 | 27.4 | 10.4 | no | stopped |
| 2026-09-28 23:57 | ISP0 | **2.0** | ~1.5 (fast path) | **yes** | stopped at 1 min |
| 2026-09-29 00:40 | ISP0 | **2.0** | **2.3** | **yes** | stopped at 1 min |

- **Run 1:** 14.6 s, inside the old 5–23 s prediction. One tick pushed ISP0 to distance 51 in every table; RouterOS's gateway check did not beat the controller. The call dropped: failover changes the public address and the flush ends old connections. ISP0 returned at 33k: ~52 min to pass 800k, ~38 before `main` considers it (110 % of ISP1), plus the 15-minute hold.
- **Run 2:** misleading. Only 10.4 s was detection; the rest was an unrelated ISP1 wobble colliding with the drill's 30 s recovery requirement.
- **Run 3:** first surviving call, after 1–2 s probes, 1 s timeout and a 1 s controller tick with emergency demotion. The scoring pass and flush ran at +18.3 s; traffic didn't wait for it. `client lag -0.3 s`, `settling tail 0.0 s`: no client-side term.
- **Run 4:** same result from a clean start. The drill now matches `ISP-fastpath` before `flush:`; it previously reported 6.8 s for a ~1.5 s demotion.
- **Open:** cutting probes to 1–1.2 s and the timeout to 500 ms should have saved over a second, yet the gap stayed 2.0 s. Two samples at 0.2 s resolution can't tell. Run more.

### Double failure

Proves: the 23 September case, never drilled on purpose.

1. Run `tools/failover-drill.py ISP0,ISP1` and pull both CPEs together.
2. Record that `NoRedundancy` reached the phone, and how long it took.
3. Record where each tier ended up.

| date | links pulled | `NoRedundancy` arrived after | tiers ended on | notes |
|---|---|---|---|---|
| 2026-09-27 07:10 | ISP0 (router rebooted) and ISP1 (not touched) | not expected: both down together for 70 s, under the 5-minute threshold | ISP2, within one tick of ISP1 dropping | unplanned; ISP0 out 2 min 40 s, ISP1 out 70 s starting 10 s after ISP0 |

Only ISP0's router was rebooted, yet ISP1 dropped 10 s later, before any flush. Either ISP1 blipped independently (it had two others that night) or one failure disturbs another. Rule out the second: check ISP1's record for 07:10–07:12 and repeat the reboot watching ISP1's probes.

### Total outage

Proves: whether a total outage reaches anyone.

1. With the work laptop on a mobile hotspot, pull all three CPEs.
2. Record what reached the phone and when. Anything that arrived came from Grafana Cloud noticing data stopped.

| date | first alert | arrived after | via |
|---|---|---|---|
| | | | |

### Operator absent

Proves: someone else can get the house back online with only [For anyone in the house](#for-anyone-in-the-house).

1. While I am away, power off the switch and leave it off.
2. Someone else gets the house online again using only that section. I answer nothing.
3. Record how long it took and every step where they hesitated, then fix the section.

| date | who | back online after | where they got stuck |
|---|---|---|---|
| | | | |

### Power

Proves: the UPS row in [Risks](06-risks-and-next.md).

1. Switch off mains to everything in the path at once.
2. Check the hEX's uptime afterwards. If it reset, the UPS changeover isn't seamless.
3. Time each device until it goes dark, or stop at two hours.

| date | device | stayed up on changeover | runtime |
|---|---|---|---|
| | | | |
