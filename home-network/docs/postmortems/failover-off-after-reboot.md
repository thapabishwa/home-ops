# Failover off after a reboot

After the router was power-cycled, the controller re-initialised in `SHADOW` mode and stopped enforcing. For 12½ hours there was no failover, and everything looked healthy.

| | |
|---|---|
| Date | After a hEX power cycle |
| Duration | **12½ hours** |
| Impact | No failover; a dead link would not have been routed around |
| Detection | I spotted it in the heartbeat; no alert |
| Root cause | Controller defaulted to shadow mode on initialisation |

## Timeline

| When | What |
|---|---|
| T+0 | hEX power-cycled; controller starts in `SHADOW` |
| T+0 to T+12½ h | Scheduler firing, run-count climbing, reputations fine; nothing enforced |
| T+12½ h | `SHADOW` spotted in the heartbeat line; enforcement restored |

## What happened

The heartbeat line read exactly like a working one except for one word: `SHADOW` instead of `ENFORCE`. Every other signal (scheduler runs, run-count, reputations) was normal.

## What changed

- The controller starts in `ENFORCE`. Shadow mode is opt-in from the terminal, so a reboot cannot disable failover: [Routing and failover](../02-routing-and-failover.md).
- A separate event watcher logs a **CRIT** when the controller stops enforcing or the router's uptime goes backwards, and its state reaches the phone as `ControllerNotEnforcing` and `ControllerStalled`: [Monitoring](../03-monitoring.md).

## Lessons

- Keeping history and alerting now are different jobs and need different programs.
