# State and secrets

Almost everything rebuilds from git. This page lists the exceptions.

## Volumes

local-path-provisioner creates PersistentVolumes as directories under a Talos user volume at `/var/mnt/local-path-provisioner` (`volumeType: directory`, carved from the system partition; the root filesystem is read-only).

| Volume | Size | Holds | If lost |
|---|---|---|---|
| Prometheus (from `storageSpec`) | 5 GiB | seven days of metrics and health-check history | nothing much; Grafana Cloud has the history |
| `config-jellyfin-0` | 10 GiB | Jellyfin's database, metadata, settings, users, watch history | restore last night's snapshot |
| `config-qbittorrent-0` | 1 GiB | qBittorrent's settings and download list | restore last night's snapshot; files stay on the media disk |
| `homenet-data` | 1 GiB | the ISP outage record (below) | restore last night's snapshot |

`homenet-data` grows about 20 KB a day:

| Path | Holds |
|---|---|
| `/data/log` | `isp-events.log`, `isp-history.csv` and rotated copies: the ISP outage record |
| `/data/state` | counter baselines; loss is a difference against these |
| `/data/www` | the dashboard feeds' last good copies |

The media library is pve's media disk over NFS (`media/library`, see [Networking](02-networking.md)).

### Backups

A `backup` CronJob in each namespace snapshots the volumes with restic to pve's media disk over NFS: `homenet-data` at 03:00 Kathmandu, both media config volumes at 03:30. It keeps 7 daily, 4 weekly and 12 (homenet) or 6 (media) monthly snapshots, and runs `restic check` after each.

- **Off the cluster, not off the laptop.** It survives a lost node disk, a deleted claim or a rebuilt cluster. Losing the ThinkPad still loses everything.
- **Jellyfin is copied live**, so its database snapshot is crash-consistent at best until a restore proves it.
- **`BackupStale`** fires through Grafana Cloud after 26 hours without a successful run.

Restore steps are in [Runbooks](09-runbooks.md). A local volume also pins its pods to the worker, which is why `dash-agent`, the CronJobs and the homenet backup run there, and the router only needs to accept the worker's address.

## Secrets

Eight, committed SOPS-encrypted beside their app (`*.sops.yaml`). Only values are encrypted, so a diff shows which Secret changed. Flux decrypts them with the age key in `flux-system/sops-age` for the `infra-configs` and `apps` Kustomizations.

| Secret | Holds | If lost |
|---|---|---|
| `homepage/homepage-secrets` | widget credentials: Proxmox API token (`HOMEPAGE_VAR_PROXMOX_TOKEN`), Jellyfin API key (`HOMEPAGE_VAR_JELLYFIN_KEY`), qBittorrent login (`HOMEPAGE_VAR_QBIT_USER`, `HOMEPAGE_VAR_QBIT_PASS`) | widgets break; Proxmox: `pveum user token add homepage@pve dashboard --privsep 0`; Jellyfin: Dashboard > API Keys |
| `homenet/homenet-credentials` | router and switch logins (`hex-api.conf`, `switch-scrape.conf`) | feeds stale, ISP watcher stops; recreate from the router account and switch admin |
| `monitoring/prometheus-credentials` | Grafana Cloud remote-write user and token | metrics and alerts stop reaching Grafana Cloud; issue a new token |
| `monitoring/mktxp-credentials` | the router's `mktxp` login | router metrics stop; recreate from the router account |
| `monitoring/grafana-admin` | local Grafana admin login | view still works, no edits; write a new password with `sops` |
| `cert-manager/internal-root-ca` | the household CA's private key | a new root is minted; every device must trust it again |
| `homenet/backup`, `media/backup` | the restic repositories' password, the same in both | the backups are unreadable; this file and either SOPS key are the only copy |

The CA Secret keeps cert-manager's annotations, so on a rebuild cert-manager adopts the restored root instead of minting a new one.

```sh
sops kubernetes/apps/homepage/secret.sops.yaml   # opens decrypted in $EDITOR, re-encrypts on save
```

### Two keys, either one enough

Every file has two recipients ([`../../.sops.yaml`](../../.sops.yaml)):

| Key | Held by | Used for |
|---|---|---|
| age `age1sjmlg66l…qfjdvw3` | the cluster (`flux-system/sops-age`) and `~/.config/sops/age/keys.txt` on the laptop | Flux decrypting; editing from the laptop |
| GPG `389C…B5EC ACA8 E170 DF19` (personal) | my keyring | **recovery**, and editing without the age key |

Recovery points:

- If the age key is lost everywhere, `sops -d` with the GPG key opens every file; `sops updatekeys` against a new age key restores the cluster. The GPG key's own backup is therefore the one that matters.
- **The GPG key expires October 2028.** Extend it before then and run `sops updatekeys`.
- The cluster has its own age key because Flux needs a passphrase-less private key in-cluster, and a compromised cluster should expose this repo's secrets, not a key that signs as me.

## The router account

The ISP scripts use the router's REST API as `homepage`, read-only, in group `dashboard`. Like every router account it is [kept out of Terraform](../../home-network/docs/05-decisions.md): a password in Terraform is a password in state, and the provider gives an account created without one a blank password. It accepts logins only from listed addresses; the worker, **10.0.0.21**, must be listed ([Incidents](07-incidents.md)).

## Other state

- **Terraform state** (`talos/terraform.tfstate`, gitignored): cluster CA keys and bootstrap tokens. Lose it and the cluster runs, but Terraform can't manage it.
- **`talosconfig`, `kubeconfig`**: admin credentials from Terraform outputs, gitignored.
- **etcd**: every object, all from git (Secrets encrypted).
