# Runbooks

Procedures for the cluster, in order.

## Where everything is

| What | Where | How to reach it |
|---|---|---|
| Kubernetes API | `talos-cp-1`, `10.0.0.20` | `https://k8s.internal:6443`, kubeconfig from `talos/` outputs |
| Talos API | both nodes, port 50000 | `talosctl`, talosconfig from `talos/` outputs |
| ingress | Traefik, `10.0.0.30` | every `<name>.internal` web name |
| deploys | Flux (Flux Operator), from `main` | https://flux.internal, `flux get kustomizations`, `flux get helmreleases -A` |
| ISP event log, history | `homenet-data` volume on the worker | `kubectl -n homenet exec deploy/dash-agent -- …` |
| Jellyfin, qBittorrent | `media` namespace; library over NFS from pve | http://10.0.0.10:8096, http://10.0.0.11:8090, or their `.internal` names |
| metrics and alert rules | Prometheus, mktxp, blackbox in `monitoring` | https://prometheus.internal, https://grafana.internal (not from the guest pool); ISP alerts come from Grafana Cloud |
| household CA | `cert-manager/internal-root-ca`; certificate at http://ca.internal | [TLS](03-tls.md) |
| Secrets | eight, SOPS-encrypted in git (`*.sops.yaml`) | `sops <file>`; key in `flux-system/sops-age` |
| VMs and Talos config | [`../talos/`](../talos/README.md) | `terragrunt plan` / `apply` |

## The cluster is down

Every web name, Jellyfin and qBittorrent go down with it. Use direct names for what runs outside:

| Instead of | Use |
|---|---|
| proxmox.internal | `https://pve.internal:8006` (pve's own certificate; the browser warns) |
| tplink.internal | `http://switch.internal` |
| home.internal | none; the dashboard runs in the cluster |

Failover runs on the router and is unaffected. **Alerts are not:** Prometheus is in the cluster, so nothing reports ISP outages. Check the router's log:
`/log print where message~"ISP-control"`.

## A change did not deploy

1. `flux get kustomizations`. If one says `Reconciliation in progress`, wait; nothing else is evidence yet.
2. If one is not Ready, its message names the blocker. `infra-controllers` blocks `infra-configs`, which blocks `apps`.
3. `flux get helmreleases -A` for the failed chart, then `kubectl -n <ns> get pods,events`.
4. Retry now: `flux reconcile kustomization flux-system --with-source`.

## A name redirects to home.internal

The catch-all caught it: Traefik has no working route for that name.

1. Ingress present? `kubectl get ingress -A | grep <name>`
2. Certificate ready? `kubectl get certificate -A`. Traefik drops an Ingress until its TLS Secret exists.
3. Service has endpoints? `kubectl -n <ns> get endpointslices`
4. `kubectl -n traefik logs deploy/traefik --since=10m | grep -i <name>`

## A 404 from 10.0.0.30

Usually plain HTTP to port 443 (`curl name.internal:443` instead of `curl https://name.internal`), or a name with no DNS record yet.

## Read the ISP record

```sh
kubectl -n homenet exec deploy/dash-agent -- tail -20 /data/log/isp-events.log
kubectl -n homenet exec deploy/dash-agent -- tail -6 /data/log/isp-history.csv
kubectl -n homenet get cronjobs,jobs
```

Dropouts per day, for a provider complaint:

```sh
kubectl -n homenet exec deploy/dash-agent -- cat /data/log/isp-events.log \
  | awk '/ISP0 DOWN/{split($1,d,"T"); c[d[1]]++} END{for(k in c) print k, c[k]}' | sort
```

## Backups

Nightly `backup` CronJobs in `homenet` and `media`; restic repositories `backups/restic-homenet` and `backups/restic-media` on pve's media disk.

```sh
kubectl -n homenet get cronjob backup                         # last successful run
kubectl -n homenet create job backup-now --from=cronjob/backup  # run one now
```

On pve, with the password from `sops -d kubernetes/apps/homenet/backup.sops.yaml`:

```sh
export RESTIC_REPOSITORY=/mnt/pve/media/backups/restic-homenet RESTIC_PASSWORD=...
restic snapshots
restic restore latest --target /root/restore      # files under /root/restore/data
```

### Restore a volume

1. `flux suspend kustomization apps`, so the next steps are not reverted.
2. Stop the writers: `kubectl -n homenet scale deploy dash-agent --replicas=0` and `kubectl -n homenet patch cronjob isp-watch isp-log -p '{"spec":{"suspend":true}}'`. For media, scale the StatefulSets to 0.
3. Restore on pve as above and `scp -r root@pve.internal:/root/restore .` to the workstation. Copy into the volume through a pod that mounts it, for example `dash-agent` scaled back to 1 (it writes only the widget caches): `kubectl -n homenet cp restore/data/log <pod>:/data/`.
4. `flux resume kustomization apps` puts every replica and schedule back.

## Use the switch's web UI

The switch allows one web session, and the dashboard's scraper logs you out. Pause it first:

```sh
kubectl -n homenet exec deploy/dash-agent -- touch /data/state/switch-scrape.pause
# … use the UI …
kubectl -n homenet exec deploy/dash-agent -- rm /data/state/switch-scrape.pause
```

## Trust the CA on a new device

Open **http://ca.internal** on the device, or see [TLS](03-tls.md).

## Add an app

1. `apps/<name>/` with its manifests and an Ingress for `<name>.internal`, annotated `cert-manager.io/cluster-issuer: internal-ca`, plus a `redirect-https` Middleware if it is browser-only.
2. Add it to `apps/kustomization.yaml`.
3. One record in `home-network/terraform/addressing.tf` pointing at `10.0.0.30`; `terragrunt apply` there.
4. Push.

## Downloads are not split across ISP1 and ISP2

The router splits by source 10.0.0.11, qBittorrent's second interface `net1` ([Networking](02-networking.md)).

1. Does the pod have it? `kubectl -n media exec qbittorrent-0 -- ip -4 addr show net1` should show 10.0.0.11, and `ip rule` a rule `from 10.0.0.11 lookup 100`.
2. If `net1` is missing, Multus did not attach it: `kubectl -n kube-system get pods -l app=multus`, and the pod's events.
3. Is qBittorrent bound to it? Options > Advanced > Network interface should be `net1`. Unbound, downloads leave as the worker, 10.0.0.21, as ordinary traffic.
4. On the router, `/ip firewall connection print count-only where src-address=10.0.0.11` counts its connections; their connection marks should be `dl-isp1` and `dl-isp2`.

## Rebuild from nothing

1. The host: [Proxmox host](../../proxmox/README.md), including the NFS export of the media disk, and the Proxmox API token for Terraform ([Talos prerequisites](../talos/README.md#prerequisites)).
2. `terragrunt apply` in `talos/`; write out the kubeconfig and talosconfig.
3. The Flux Operator, a deploy key and the `FluxInstance` ([Talos after apply](../talos/README.md#after-apply)).
4. Put the age key back **before** Flux reaches the Secrets:
   `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=<key file>`.
   Flux then decrypts every Secret from git, the CA's included, so the root is restored and devices keep trusting it.
5. Restore `homenet-data`, `config-jellyfin-0` and `config-qbittorrent-0` from last night's snapshots ([Backups](#backups)). Without them the ISP history starts empty, Jellyfin starts at its setup wizard and the download list is empty; the media files are safe on the media disk.
