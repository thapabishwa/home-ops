# Proxmox host

A ThinkPad P52 run as a server: lid closed, on permanent AC, hosting the two
Talos VMs and the media disk the cluster reads over NFS. Ansible applies its
configuration.

| Hardware | |
|---|---|
| CPU | i7-8850H, 6 cores / 12 threads |
| Memory | 46 GiB |
| Disks | NVMe thin pool, 141 GiB (VM and container disks); media disk, 916 GiB at `/mnt/pve/media` |
| GPU | Quadro P1000 (unused) |

## What it does

| | Setting | Why |
|---|---|---|
| Fan | `fan-curve.py`, polling every 10 s | The stock curve left the fan at 0 rpm with the package at 94 °C; a fixed top speed runs the bearing at 3,575 rpm forever. Ramps earlier than stock, never stops, ~4 °C hysteresis. Unregulated above 88 °C. |
| CPU | `powersave` governor, turbo off | Bounds peak temperature under sustained load. |
| Battery | charge held at 75–80 % | Permanent AC wears a pack held at 100 %. At 80 % it still covers outages. |
| GPU | `nouveau` blacklisted | The Quadro P1000 is unused; nouveau races the integrated GPU for device numbers. |
| Thermal trail | `log-temp.sh` every minute | Temperature, fan and load to the journal, so an abrupt shutdown leaves a record. |
| Journal | 1 GB, six months, persistent | The default kept about two days. |
| Dashboard feed | `power-json.sh` every minute | Battery, temperature and fan, PUT to `dash.internal` for Homepage. Published only if it looks like a real reading. |
| Media | NFS export of `/mnt/pve/media` to 10.0.0.20/31 | All clients mapped to uid 100000, so files from pods and the host share an owner. The cluster's nightly backups land in `backups/`. |
| Restores | `restic` installed | Reads those backups on the host ([Runbooks](../kubernetes/docs/09-runbooks.md)). |
| Web UI | subscription notice patched after every `apt` run | An apt hook re-applies it; updates restore the notice. |

## Applying it

[`ansible/site.yml`](ansible/site.yml), from a workstation, as root over SSH:

```sh
cd proxmox/ansible
ansible-playbook site.yml --check --diff   # drift check: changed=0 when converged
ansible-playbook site.yml --diff           # apply
```

Files in [`ansible/files/`](ansible/files/) are byte-for-byte what runs on the
host. A change restarts only what it touches; kernel module options apply at
the next reboot.

## Not managed

- `/etc/network/interfaces`: Ansible arrives over it, and a tool shouldn't own
  the path it arrives on (the router's
  [management path](../home-network/docs/05-decisions.md) follows the same
  rule). The host is `vmbr0`, 10.0.0.3/24, gateway 10.0.0.1.
- `/etc/pve/`: storage, VM and container config live in Proxmox's cluster
  filesystem. The Talos VMs are Terraform's, in
  [`kubernetes/talos/`](../kubernetes/talos/README.md).
- Proxmox itself: install, repositories, upgrades.

## Rebuild

1. Install Proxmox VE at 10.0.0.3, with the media disk at `/mnt/pve/media`.
2. Add the workstation's SSH key to `/root/.ssh/authorized_keys`.
3. `ansible-playbook site.yml --diff`, then reboot once for the module options.
4. Create the Proxmox API token for Terraform, then build the cluster:
   [Talos on Proxmox](../kubernetes/talos/README.md).
