# Kubernetes

A two-node Talos cluster on the Proxmox host, deployed from this repository by Flux. A push to `main` is the deploy.

## What it runs

- **The front door.** Every `<name>.internal` name resolves to 10.0.0.30, where Traefik routes it to an app, or to pve's and the switch's web UIs.
- **HTTPS** on every name, from a household CA constrained to `.internal`.
- **Homepage**, its data feeds, and the jobs that record every ISP outage.
- **Prometheus**, whose rules raise the network's alerts.
- **Jellyfin and qBittorrent**, with the media disk over NFS.

## Why a cluster

Resources were never the case: a read-only audit on 9 October 2026 found six small services using **3.7 GiB of 46 GiB**. The case was tooling I know well (Flux, the Prometheus Operator, Grafana, cert-manager, Multus), and Flux pulls its own deploys, which CGNAT requires. Rejected: a hand-built sync agent (one more tool to maintain), push from GitHub (nothing can reach in), and Ansible (push-based).

## The dependency it creates

Every `.internal` name goes through the cluster; if both Talos VMs are down, so are the names. Failover does not depend on it: it runs on the router, so losing the cluster loses only visibility of an outage.

## What's next

Non-goals: high availability (both nodes share one laptop) and exposing anything to the internet.

1. **Copy the backups off the laptop.** Nightly snapshots of `homenet-data`, Jellyfin and qBittorrent land on pve's media disk, so losing the ThinkPad still loses them.
2. **A real domain for HTTPS on the TV**, with Let's Encrypt via DNS-01.
3. **A dead-man's switch outside the house**: route the always-firing `Watchdog` alert to an external heartbeat service.
4. **Deliver the cluster's own alerts**: node and pod rules evaluate but nothing sends them anywhere.

## Pages

- [Architecture](docs/01-architecture.md)
- [Networking](docs/02-networking.md)
- [TLS](docs/03-tls.md)
- [Apps](docs/04-apps.md)
- [Monitoring](docs/05-monitoring.md)
- [State and secrets](docs/06-state-and-secrets.md)
- [Incidents](docs/07-incidents.md)
- [Decisions](docs/08-decisions.md)
- [Runbooks](docs/09-runbooks.md)
- [Implementation: VMs and Talos](talos/README.md)

Manifests live under [`clusters/home/`](clusters/home/), [`infrastructure/`](infrastructure/) and [`apps/`](apps/). DNS names are in the router's [`addressing.tf`](../home-network/terraform/addressing.tf).
