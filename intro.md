# home-ops

Notes on what I run at home: how it's built, how to operate it, and what went
wrong. Reference pages are kept short; the longer stories are postmortems.
Start with the [design](design.md): the whole system on one page.

## Home network

I work from home in Kathmandu, so the network is my work uplink first. Three
consumer ISPs terminate on one MikroTik hEX over a single 30 m VLAN trunk.
Devices are tiered by class, and a controller demotes a failing link in about
two seconds.

[Overview](home-network/README.md) · [Architecture](home-network/docs/01-architecture.md) · [Incidents](home-network/docs/04-incidents.md) · [Runbooks](home-network/docs/07-runbooks.md)

## Kubernetes

A two-node Talos cluster on the same laptop, deployed by Flux from this repo.
It runs every household service: media, downloads, the dashboard, the ISP
monitoring and alerting. Each service gets a `.internal` name and HTTPS from a
name-constrained private CA.

[Overview](kubernetes/README.md) · [Architecture](kubernetes/docs/01-architecture.md) · [Incidents](kubernetes/docs/07-incidents.md) · [Runbooks](kubernetes/docs/09-runbooks.md)

## Proxmox host

The ThinkPad underneath, run as a server: fan curve, battery cap, thermals and
the NFS export, applied by Ansible.

[Proxmox host](proxmox/README.md)

## Conventions

- Numbers come from a drill, a log, a screenshot or a published price.
  Estimates say so.
- Wrong diagnoses stay in the record, marked as disproven.
- Code: [github.com/thapabishwa/home-ops](https://github.com/thapabishwa/home-ops).
