# Decisions

Choices that could have gone the other way. Router-side ones are in the [home network's decisions](../../home-network/docs/05-decisions.md).

### Run a cluster at all

Kubernetes for six small services.

- **Why:** GitOps, Prometheus, cert-manager and a private CA are tools I know well ([Overview](../README.md)).
- **Rejected:** Ansible against the containers; fits the size, but a one-off.
- **Result:** the front door within a day, every household service within the week.
- **Revisit:** if keeping the cluster running takes more time than the services it runs.

### Talos on Proxmox VMs

Talos in two VMs, clear of Proxmox's networking.

- **Why:** the OS should be only an API and a config file.
- **Rejected:** k3s on the host; Kubernetes in LXC.
- **Cost:** two VMs' overhead, and Talos-specific setup for storage, Pod Security and kubelet certificates.
- **Revisit:** if a second physical host arrives; Talos on bare metal then removes a layer.

### Flux, pulling

One `FluxInstance`, managed by the Flux Operator, with its web UI.

- **Why:** all three ISPs are behind CGNAT, so nothing can push in.
- **Rejected:** a self-hosted GitHub runner on a public repo; a hand-written sync agent.
- **Cost:** a broken controller blocks every app behind it, and a rebuild installs the operator first.

### A private CA, name-constrained

A household CA limited to `.internal`.

- **Why:** no public CA issues for `.internal`.
- **Rejected:** no TLS; skipping verification; a real domain with Let's Encrypt (maybe later, as the only route to HTTPS on the TV).
- **Cost:** each device trusts the root once. The TV's Jellyfin app rejects user CAs, so Jellyfin stays HTTP ([TLS](03-tls.md)).
- **Revisit:** when HTTPS on the TV is needed.

### Proxmox proxied, certificate verified

- **Why:** pve's login needs HTTPS; skipping verification hides a man in the middle.
- **Rejected:** redirecting to `pve.internal:8006`; `insecureSkipVerify`.
- **Cost:** pve's root is committed; it expires in 2036.

### Secrets in git with SOPS and age

- **Why:** a rebuild should be Terraform and a push, and Flux decrypts SOPS natively.
- **Rejected:** hand-made Secrets; KSOPS, unnecessary with Flux; an external store.
- **Cost:** two recipients per file, age and a GPG recovery key ([State and secrets](06-state-and-secrets.md)).

### The media disk over NFS

NFS from pve, mapped to the host containers' uid.

- **Why:** the library is a 916 GB disk the host still uses.
- **Rejected:** passthrough (takes it from the host); virtiofs (needs a Talos extension).
- **Cost:** the media apps also depend on pve's NFS server.
- **Revisit:** if the NFS dependency causes a media outage.

### qBittorrent's address via Multus and macvlan

A macvlan second interface, attached by Multus.

- **Why:** the download split matches source 10.0.0.11, but pod traffic leaves as its node.
- **Rejected:** matching the worker's address (splits every pod on it); keeping qBittorrent in a container.
- **Cost:** Multus fronts every pod's network setup, and worker pods reach qBittorrent through its Service ([Networking](02-networking.md)).

### Prometheus through the Prometheus Operator

The operator, with health checks as blackbox `probe_success` series.

- **Why:** metrics and health checks need history and alerts.
- **Rejected:** a plain Deployment and ConfigMap (restarts, since `subPath` mounts never update); Gatus (own SQLite history, no alerting); Homepage's status dots (no history).
- **Cost:** CRDs install with the controllers, `monitoring` is privileged, and localhost-bound control-plane metrics go unscraped ([Monitoring](05-monitoring.md)).

### A split Grafana

ISP data and health checks in Grafana Cloud; the rest at home.

- **Why:** ISP data must alert when the house is in trouble. Health checks add about 300 series; cluster metrics are about 80,000 against a 10,000 free tier.
- **Rejected:** all in the cloud (eight times the tier); all at home (no ISP alerts when the cluster or uplink is down).
- **Cost:** a remote-write filter is the boundary, and cluster history is seven days, uncopied.
- **Revisit:** if the free tier changes, or the cluster's own alerts need to survive the cluster.
